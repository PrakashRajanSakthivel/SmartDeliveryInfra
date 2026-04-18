# Adding a Worker Node to the k3s Cluster

Step-by-step account of adding `sd-worker-0` (Hetzner CX22, 62.238.11.224) to the existing single-node k3s cluster running on `sd-master` (46.62.150.44 / 10.0.0.2).

Both nodes sit on a Hetzner private network (`10.0.0.0/16`):

| Node | Public IP | Private IP | Role |
|---|---|---|---|
| sd-master | 46.62.150.44 | 10.0.0.2 | k3s server |
| sd-worker-0 | 62.238.11.224 | 10.0.0.4 | k3s agent |

---

## Phase 1 — Provision & Connect

1. Generate an ed25519 key pair for the worker and paste the public key into the Hetzner console during server creation.
2. Set `~/.ssh/config` entries for both hosts with their public IPs and port `2222`.
3. Change the worker's SSH port to `2222` to match the master.

---

## Phase 2 — Join the Cluster

On `sd-master`, retrieve the cluster token and private IP:

```bash
cat /var/lib/rancher/k3s/server/node-token
ip addr show enp7s0   # → 10.0.0.2
```

On `sd-worker-0`, install the k3s agent **matching the master version (v1.33.3)** and bind it to the private interface:

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.33.3+k3s1 \
  K3S_URL=https://10.0.0.2:6443 \
  K3S_TOKEN=<token> \
  sh -s - --flannel-iface=enp7s0 --node-ip=10.0.0.4
```

Verify on master:

```bash
kubectl get nodes -o wide   # sd-worker-0 should appear Ready
```

Open required inbound ports in Hetzner Firewall (source `10.0.0.0/16`):

| Port | Protocol | Purpose |
|---|---|---|
| 8472 | UDP | Flannel VXLAN |
| 10250 | TCP | kubelet API |
| 15012 | TCP | istiod xDS / cert |
| 15017 | TCP | istiod webhook |

---

## Phase 3 — Problems Encountered and Fixes

### Problem 1 — `kubectl logs` / `kubectl exec` returning 502 Bad Gateway

**Symptom:** Node shows `Ready`, pods schedule, but any log or exec call to a worker pod returns HTTP 502.

**Diagnosis:** k3s uses a reverse WebSocket tunnel (`wss://<server>:6443/v1-k3s/connect`) for all proxy operations — not direct TCP to port 10250. The agent was connecting to `wss://46.62.150.44:6443` (the master's **public** IP) instead of the private IP. Hetzner firewall allowed port 6443 only on the private network, so the tunnel never established. Error in k3s server logs: `failed to find Session for client sd-worker-0`.

**Fix:** Add `advertise-address` and `node-ip` to `/etc/rancher/k3s/config.yaml` on the master so the server advertises its private IP:

```yaml
# /etc/rancher/k3s/config.yaml
advertise-address: "10.0.0.2"
node-ip: "10.0.0.2"
```

Restart k3s server (`systemctl restart k3s`), then restart the agent (`systemctl restart k3s-agent`). Verify the agent now connects through the private IP:

```bash
journalctl -u k3s-agent --since "1 min ago" | grep tunnel
# Expected: wss://10.0.0.2:6443/v1-k3s/connect
```

---

### Problem 2 — Version Skew (worker installed v1.34.6 vs master v1.33.3)

**Symptom:** 502 persisted after the tunnel fix in early attempts.

**Root cause:** The default `k3s.io` installer pulled the latest agent version (`v1.34.6`). Kubernetes requires agents to be ≤ the server version; a **newer** agent than the server causes API incompatibilities and a broken proxy handshake.

**Fix:** Reinstall the agent pinning `INSTALL_K3S_VERSION=v1.33.3+k3s1` (matching the master), then rotate the stale kubelet serving cert:

```bash
# On worker
systemctl stop k3s-agent
rm -f /var/lib/rancher/k3s/agent/serving-kubelet.crt \
       /var/lib/rancher/k3s/agent/serving-kubelet.key
systemctl start k3s-agent
```

---

### Problem 3 — Istio Sidecars on Worker Can't Resolve DNS (CoreDNS timeout)

**Symptom:** After the tunnel fix, pods on the worker were stuck at `0/2`. Istio proxy logs showed:

```
dial tcp: lookup istiod.istio-system.svc on 10.43.0.10:53: i/o timeout
```

**Diagnosis:** CoreDNS ClusterIP `10.43.0.10` was unreachable from the worker. `iptables` DNAT rules were present (`10.43.0.10:53 → 10.42.0.114:53`), but the CoreDNS pod IP `10.42.0.114` (on master) was also unreachable — confirming that Flannel VXLAN between the two nodes was broken.

```bash
# On worker
ping -c 3 10.42.0.114   # 100% packet loss — VXLAN confirmed down
```

---

### Problem 4 — Flannel VXLAN Broken: Stale Public-IP Annotation

**Symptom:**  
- Worker FDB showed `dst 46.62.150.44` (master's **public** IP)  
- Worker's Hetzner firewall UDP 8472 rule only covers `10.0.0.0/16` → packets to public IP dropped

**Root cause:** When the master first registered with k3s before `advertise-address` was set, Flannel stored the public IP in a node annotation:

```
flannel.alpha.coreos.com/public-ip = 46.62.150.44
```

Changing `advertise-address` later did **not** update this annotation. All worker nodes read it to populate their VXLAN FDB, so VXLAN packets were sent to the public IP.

**Fix:** Patch the annotation on the master node:

```bash
kubectl annotate node sd-master \
  flannel.alpha.coreos.com/public-ip=10.0.0.2 \
  flannel.alpha.coreos.com/public-ip-overwrite=10.0.0.2 \
  --overwrite
```

Restart the agent to rebuild the FDB. Verify:

```bash
# On worker
bridge fdb show dev flannel.1   # must show: dst 10.0.0.2
ping -c 3 10.42.0.114           # must succeed
```

---

### Problem 5 — VXLAN Asymmetric: Master Still Sending from Public IP

**Symptom:** After patching the annotation, worker→master VXLAN worked, but master→worker was still dropping (100% loss in both directions from master).

**Diagnosis:** `tcpdump` on the master captured:

```
10.0.0.4  → 10.0.0.2:8472   ← worker sends via private IP  ✅
46.62.150.44 → 10.0.0.4:8472 ← master REPLIES via public IP ❌
```

**Root cause:** `advertise-address` and `node-ip` were set, but `flannel-iface` was never added. Flannel on the master followed the default route and picked the public-IP interface (`eth0` / `46.62.150.44`) for VXLAN encapsulation.

**Fix:** Add `flannel-iface` to the master config and restart:

```yaml
# /etc/rancher/k3s/config.yaml  (final state)
advertise-address: "10.0.0.2"
node-ip: "10.0.0.2"
flannel-iface: "enp7s0"
```

```bash
systemctl restart k3s
sleep 30
```

Confirm VXLAN now sources from the private IP:

```bash
# On master (terminal 1)
tcpdump -i enp7s0 udp port 8472 -n -c 5
# All packets: src 10.0.0.2  ← private IP ✅

# On worker (terminal 2)
ping -c 3 10.42.0.114   # now has replies ✅
```

---

## Phase 4 — Final Verification

After all fixes, trigger a rolling restart to spread pods across both nodes:

```bash
kubectl rollout restart deployment -n smartdelivery
kubectl rollout restart deployment -n istio-system
kubectl get pods -n smartdelivery -o wide -w
```

Expected final state — all pods `2/2 Running`, distributed across both nodes:

```
NAME                                 READY   STATUS    NODE
auth-service-...                     2/2     Running   sd-master
auth-service-...                     2/2     Running   sd-worker-0
cart-service-...                     2/2     Running   sd-master
cart-service-...                     2/2     Running   sd-worker-0
order-service-...                    2/2     Running   sd-master
order-service-...                    2/2     Running   sd-worker-0
payment-service-...                  2/2     Running   sd-worker-0
restaurent-service-...               2/2     Running   sd-master
restaurent-service-...               2/2     Running   sd-worker-0
```

---

## Key Lessons

| Lesson | Detail |
|---|---|
| Always pin the agent version | Worker must be ≤ server version. Use `INSTALL_K3S_VERSION` explicitly. |
| Set all three config keys together | `advertise-address`, `node-ip`, **and** `flannel-iface` must all be set before the first join. |
| Flannel annotation is not auto-updated | Changing `advertise-address` after first startup requires manually patching `flannel.alpha.coreos.com/public-ip` on the node. |
| Hetzner private network + firewall | UDP 8472 rule must cover `10.0.0.0/16` (private). VXLAN using the public IP is silently dropped. |
| VXLAN is asymmetric without `flannel-iface` | Traffic can work one-way (worker→master) while the reverse path is broken — making diagnosis harder. |
| Rotate kubelet cert after reinstall | After reinstalling at a different version, delete the stale `serving-kubelet.crt` / `.key` so a fresh cert is issued by the cluster CA. |

---

## Final Cluster Config

**`/etc/rancher/k3s/config.yaml` on sd-master:**

```yaml
advertise-address: "10.0.0.2"
node-ip: "10.0.0.2"
flannel-iface: "enp7s0"
```

**k3s agent install command for sd-worker-0:**

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.33.3+k3s1 \
  K3S_URL=https://10.0.0.2:6443 \
  K3S_TOKEN=<token> \
  sh -s - --flannel-iface=enp7s0 --node-ip=10.0.0.4
```
