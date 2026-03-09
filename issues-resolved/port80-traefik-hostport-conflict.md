# Issue: Port 80 Blocked — Traefik hostPort Conflicting with Istio IngressGateway

**Date Resolved:** March 9, 2026
**Affected Component:** Istio IngressGateway → nginx → Public URL
**Environment:** k3s + Istio service mesh, Hetzner VPS, Cloudflare DNS

---

## Problem Statement

After opening port 80 in the Hetzner firewall and configuring nginx as a reverse proxy (port 80 → localhost:30774), external requests to `http://smartdeliveryapi.rajanlabs.com` were timing out (`ETIMEDOUT`). Even after removing the Hetzner firewall entirely, port 80 remained unreachable externally.

---

## Symptoms

- `Test-NetConnection -ComputerName 46.62.150.44 -Port 80` → `TcpTestSucceeded: False`
- Port 30774 worked fine externally
- `curl http://localhost/...` inside VPS → nginx responded (404 default site, then 426 after fix)
- Hetzner firewall showed "Fully applied" with port 80 rule present
- UFW: inactive. Standard `iptables -L INPUT` showed no DROP/REJECT rules

---

## Root Cause

k3s ships with **Traefik** as its default ingress controller. Traefik uses a `ServiceLB` (svclb) pod that claims `hostPort: 80` and `hostPort: 443` on the node. The k3s CNI (flannel + nftables) installs a DNAT rule:

```
tcp dport 80 → dnat to 10.42.0.95:80   (svclb-traefik pod)
```

This rule intercepts all inbound port 80 TCP traffic at the nftables level **before it reaches nginx or Istio IngressGateway**. The traffic was being forwarded to Traefik, which returned nothing useful (connection refused / 426).

Confirmed with:
```bash
sudo nft list ruleset | grep "tcp dport 80.*dnat"
# tcp dport 80 counter packets 65 bytes 3472 dnat to 10.42.0.95:80

kubectl get pods -A -o wide | grep 10.42.0.95
# kube-system  svclb-traefik-b2f07a78-qr6lv  (hostPort 80 owner)
```

Both `svclb-traefik` and `svclb-istio-ingressgateway` had `hostPort: 80` — Traefik won the race.

---

## Fix

Patch Traefik service from `LoadBalancer` to `ClusterIP`, which removes the svclb pod and its hostPort DNAT rule:

```bash
kubectl patch svc traefik -n kube-system -p '{"spec": {"type": "ClusterIP"}}'
```

This frees port 80 for `svclb-istio-ingressgateway`, which already has `hostPort: 80` configured. Traffic now flows:

```
Internet → port 80 → Istio IngressGateway (NodePort 30774 internally) → VirtualService → Services
```

---

## Verification

```bash
curl -H "Host: smartdeliveryapi.rajanlabs.com" http://46.62.150.44/orderservice/api/diagnostics/chain
# 200 OK — OrderService + RestaurantService downstream

# With Cloudflare orange cloud + Flexible SSL:
# GET https://smartdeliveryapi.rajanlabs.com/orderservice/api/diagnostics/chain → 200 OK
```

---

## Additional Issues Encountered Along the Way

### 1. nginx default_server intercepting requests
**Symptom:** curl with correct Host header → nginx 404
**Fix:** Remove the default site symlink: `sudo rm /etc/nginx/sites-enabled/default`

### 2. nginx HTTP/1.0 upstream → Istio 426
**Symptom:** nginx proxied request → `426 Upgrade Required` from Istio/Envoy
**Fix:** Add `proxy_http_version 1.1;` to nginx location block. Envoy requires HTTP/1.1.

### 3. HPA scale cascade from pod restart
**Symptom:** All 5 services scaled to 5 replicas, each pod pegged at ~203m CPU (at limit), no real traffic
**Root Cause:** A pod restarted overnight → .NET JIT on startup spiked CPU → HPA triggered scale-up → each new pod also JIT-compiled → cascade. All pods throttled at 200m CPU limit.
**Fix:**
```bash
kubectl apply -f release/*/  # with maxReplicas set to 1 temporarily
kubectl rollout restart deployment auth-service cart-service order-service payment-service restaurent-service
```

---

## Interview Talking Points

- **k3s includes Traefik by default** — if you're using Istio or another ingress, Traefik competes for hostPort 80/443 via ServiceLB pods. Disable it or patch to ClusterIP.
- **nftables is the enforcement layer on Ubuntu 24.04** — `iptables -L` may show nothing while nftables has active DNAT rules. Always check `nft list ruleset`.
- **Envoy/Istio requires HTTP/1.1** — nginx defaults to HTTP/1.0 for upstream proxy connections. Always add `proxy_http_version 1.1;` when proxying to Envoy.
- **HPA + low CPU limits = JIT cascade** — .NET apps spike CPU on startup. If CPU limit is too close to steady-state usage, a single pod restart triggers unbounded scale-up.
- **Cloudflare Flexible SSL** — Cloudflare terminates TLS externally and proxies plain HTTP to origin on port 80. No certificate needed on the origin server.
