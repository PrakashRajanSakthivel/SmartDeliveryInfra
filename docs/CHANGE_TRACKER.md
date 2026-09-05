# SmartDelivery — Change Tracker

> Track all infrastructure changes: what exists, what is changing, why, and current status.
> Update this file before and after every change.

---

## How to Use This File

| Column | Meaning |
|--------|---------|
| **Status** | `Planned` / `In Progress` / `Done` / `Rolled Back` |
| **Before** | Exact current state in the cluster/repo |
| **After** | Exact desired state |
| **Apply command** | The exact command to run |
| **Verified** | How to confirm it worked |

---

## Testing Protocol (apply to every change)

Every change must pass these checks in order before marking `Done`.

### T1 — Pod health check
```bash
kubectl get pods -n smartdelivery
kubectl get pods -n istio-system
# All pods must be Running and Ready (e.g. 2/2 for sidecar pods)
```

### T2 — Port-forward direct to service (bypasses gateway — tests the service itself)
```bash
# Replace <service-name> with: auth-service / order-service / cart-service / payment-service / restaurent-service
kubectl port-forward svc/<service-name> 8080:8080 -n smartdelivery
```
Then in a second terminal or Postman/Bruno:
```
GET http://localhost:8080/api/diagnostics/ping
```
Expected: `200 OK`
> This confirms the pod and sidecar are healthy independently of ingress.

### T3 — Port-forward to IngressGateway (tests gateway + virtualservice routing)
```bash
kubectl port-forward svc/istio-ingressgateway 9080:80 -n istio-system
```
Then call with `Host` header:
```
GET http://localhost:9080/orderservice/api/diagnostics/ping
Host: smartdeliveryapi.rajanlabs.com
```
Expected: `200 OK`
> This confirms Gateway and VirtualService rules are correct without needing public DNS or firewall.

### T4 — Public URL test (tests full external path: DNS → NodePort → Gateway → Service)
```bash
curl http://smartdeliveryapi.rajanlabs.com:30774/orderservice/api/diagnostics/ping
```
Expected: `200 OK`

### T5 — IngressGateway logs (if any test above fails)
```bash
kubectl logs -l app=istio-ingressgateway -n istio-system --tail=50
```
Look for: `404` (route not matched), `503` (pod unreachable), or connection errors.

---

## Change Log

---

### CHG-001 — Switch public hostname from `api.smartdelivery.local` to `smartdeliveryapi.rajanlabs.com`

| Field | Detail |
|-------|--------|
| **Date** | 2026-03-08 |
| **Status** | ✅ Done |
| **Reason** | `api.smartdelivery.local` is not a real DNS name — cannot be resolved by external clients (browsers, UI hosted on Azure Static Website, Postman without manual hosts file edit). Moving to a real public subdomain. |

#### Phase 1 — Verify OrderService is healthy (port-forward, no gateway involved)

> Do this first. Confirm the pod itself works before touching any routing config.

```bash
# Step 1: port-forward directly to order-service
kubectl port-forward svc/order-service 8080:8080 -n smartdelivery

# Step 2: in Postman/Bruno or curl
GET http://localhost:8080/api/diagnostics/ping

# Expected: 200 OK
# If 404: check exact endpoint path in OrderService code
# If connection refused: pod not running (check kubectl get pods -n smartdelivery)
```

**Status:** ✅ Done — 200 OK confirmed 2026-03-08

---

#### Phase 2 — Update Gateway + VirtualService to use real domain

> Only proceed after Phase 1 passes.

#### Step 1 — Cloudflare DNS ✅ Done

| | Before | After |
|--|--------|-------|
| DNS record | None | `A` record: `smartdeliveryapi` → `46.62.150.44` |
| Proxy status | — | DNS only (grey cloud) — **not proxied** |
| Full domain | — | `smartdeliveryapi.rajanlabs.com` |

**Test:**
```bash
nslookup smartdeliveryapi.rajanlabs.com
# Expected: Address: 46.62.150.44
```
> DNS propagation can take 1–5 minutes. If it doesn't resolve, wait and retry.

---

#### Step 2 — Istio Gateway (`istio-gateway-config.yaml`)

**File:** `istio-gateway-config.yaml`

Before:
```yaml
hosts:
- "api.smartdelivery.local"
```

After:
```yaml
hosts:
- "smartdeliveryapi.rajanlabs.com"
```

**Apply:**
```bash
kubectl apply -f istio-gateway-config.yaml
```

**Test:**
```bash
# 1. Confirm the resource has the new hostname
kubectl get gateways.networking.istio.io -n istio-system -o yaml | grep hosts -A2
# Expected: - smartdeliveryapi.rajanlabs.com

# 2. Port-forward to IngressGateway and test with new Host header (T3)
kubectl port-forward svc/istio-ingressgateway 9080:80 -n istio-system
# In Postman/Bruno: GET http://localhost:9080/orderservice/api/diagnostics/ping
# Header → Host: smartdeliveryapi.rajanlabs.com
# Expected: 200 OK

# 3. Confirm old hostname no longer works (regression check)
# In Postman/Bruno: GET http://localhost:9080/orderservice/api/diagnostics/ping
# Header → Host: api.smartdelivery.local
# Expected: 404 (no matching gateway rule)
```

**Status:** ✅ Done — 200 OK confirmed 2026-03-08

> ⚠️ **Troubleshooting note (2026-03-08):** When testing via gateway, `/api/diagnostics/ping` only returns OrderService info — no downstream call. Use `/api/diagnostics/chain` to verify the full OrderService → RestaurantService propagation chain. Both endpoints return 200; the difference is intentional by design. (`release/RestaurentService/smartdelivery-virtualservice.yaml`)

**File:** `release/RestaurentService/smartdelivery-virtualservice.yaml`

Before:
```yaml
hosts:
- "api.smartdelivery.local"
```

After:
```yaml
hosts:
- "smartdeliveryapi.rajanlabs.com"
```

**Apply:**
```bash
kubectl apply -f release/RestaurentService/smartdelivery-virtualservice.yaml
```

**Test:**
```bash
# 1. Confirm the resource has the new hostname
kubectl get virtualservice smartdelivery-vs -n smartdelivery -o yaml | grep hosts -A2
# Expected: - smartdeliveryapi.rajanlabs.com

# 2. Port-forward to IngressGateway and test each service route (T3)
kubectl port-forward svc/istio-ingressgateway 9080:80 -n istio-system

# Test each route in Postman/Bruno with Header → Host: smartdeliveryapi.rajanlabs.com
#   GET http://localhost:9080/authservice/api/auth/login        → expect 200 or 405
#   GET http://localhost:9080/orderservice/api/diagnostics/ping → expect 200
#   GET http://localhost:9080/cartservice/api/cart              → expect 200 or 401
#   GET http://localhost:9080/paymentservice/api/payment        → expect 200 or 405
#   GET http://localhost:9080/restaurentservice/api/restaurants → expect 200

# 3. Check IngressGateway logs if any route returns unexpected response
kubectl logs -l app=istio-ingressgateway -n istio-system --tail=50
```

**Status:** ✅ Done — 200 OK confirmed 2026-03-08

---

#### Step 4 — End-to-End Public Test

```bash
# Full path: DNS → Hetzner NodePort 30774 → IngressGateway → VirtualService → Pod
curl http://smartdeliveryapi.rajanlabs.com:30774/orderservice/api/diagnostics/ping

# Expected: 200 OK
# If ERR_NAME_NOT_RESOLVED → DNS not propagated yet (wait, retry Step 1)
# If timeout              → Hetzner firewall blocking 30774 (check firewall rules)
# If 404 (fast response)  → Gateway reached but path wrong on the service
# If 503                  → Gateway reached but pod is unhealthy (check T1 + T5)
```

Run all 5 service routes to confirm full VirtualService routing:
```bash
curl http://smartdeliveryapi.rajanlabs.com:30774/authservice/api/auth/login
curl http://smartdeliveryapi.rajanlabs.com:30774/restaurentservice/api/restaurants
curl http://smartdeliveryapi.rajanlabs.com:30774/orderservice/api/diagnostics/ping
curl http://smartdeliveryapi.rajanlabs.com:30774/cartservice/api/cart
curl http://smartdeliveryapi.rajanlabs.com:30774/paymentservice/api/payment
```

**Status:** 🔲 Not done yet — next step: test via public URL `smartdeliveryapi.rajanlabs.com:30774` (when applicable)

Before:
```env
# Was using raw IP or local hostname
VITE_API_BASE_URL=http://46.62.150.44:30774
```

After:
```env
VITE_API_BASE_URL=http://smartdeliveryapi.rajanlabs.com:30774
```

> CORS: ensure `.NET` services allow origin `https://<storageaccount>.z13.web.core.windows.net`

---

#### Rollback Plan (CHG-001)

If anything breaks, revert files and re-apply:

```bash
# Revert gateway host
# Edit istio-gateway-config.yaml: hosts back to "api.smartdelivery.local"
kubectl apply -f istio-gateway-config.yaml

# Revert virtualservice
# Edit smartdelivery-virtualservice.yaml: hosts back to "api.smartdelivery.local"
kubectl apply -f release/RestaurentService/smartdelivery-virtualservice.yaml
```

---

---

### CHG-002 — Remove port from public URL (nginx reverse proxy)

| Field | Detail |
|-------|--------|
| **Date** | TBD — after CHG-001 is Done |
| **Status** | 🔲 Planned |
| **Reason** | Users should call `http://smartdeliveryapi.rajanlabs.com/...` not `....:30774/...` |
| **Approach** | Install nginx on the VPS node. nginx listens on port 80, proxies to `localhost:30774`. No Istio change needed. |

#### Steps

**1. Install nginx on VPS**
```bash
sudo apt update && sudo apt install nginx -y
```

**2. Create nginx site config**
```bash
sudo nano /etc/nginx/sites-available/smartdeliveryapi
```
Paste:
```nginx
server {
    listen 80;
    server_name smartdeliveryapi.rajanlabs.com;

    location / {
        proxy_pass         http://localhost:30774;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
```

**3. Enable the site**
```bash
sudo ln -s /etc/nginx/sites-available/smartdeliveryapi /etc/nginx/sites-enabled/
sudo nginx -t        # test config — must say "ok"
sudo systemctl reload nginx
```

**4. Open port 80 in Hetzner firewall**
Add inbound TCP rule for port `80` from `0.0.0.0/0` in Hetzner console.

**Test:**
```bash
# No port in URL — goes through nginx → 30774 → Istio
curl http://smartdeliveryapi.rajanlabs.com/orderservice/api/diagnostics/ping
# Expected: 200 OK
```

**Status:** 🔲 Not done yet

---

### CHG-003 — Enable HTTPS via Cloudflare proxy (orange cloud)

| Field | Detail |
|-------|--------|
| **Date** | TBD — after CHG-002 is Done |
| **Status** | 🔲 Planned |
| **Reason** | Plain HTTP leaks credentials. HTTPS required for any real UI or Azure Static Website integration. |
| **Pre-requisite** | CHG-002 (nginx, port 80) must be done first. |
| **Approach** | Use Cloudflare's built-in SSL — no certbot or Let's Encrypt needed. Cloudflare terminates HTTPS at the edge, forwards HTTP to the VPS on port 80. Free, zero-config cert managed by Cloudflare. |

> **Why not certbot?** Currently DNS only (grey cloud) — Cloudflare is just acting as DNS. Switching to orange cloud gives free HTTPS instantly with Flexible SSL mode. Certbot would only be needed if Full Strict mode is required (not necessary for a showcase).

#### Steps

**1. In Cloudflare dashboard — SSL/TLS → Overview**
Set SSL mode to **Flexible**
> Flexible = Browser → Cloudflare is HTTPS, Cloudflare → VPS is HTTP. No cert needed on VPS.

**2. In Cloudflare DNS — flip to orange cloud**
Edit the `smartdeliveryapi` A record → toggle Proxy status from grey to **orange**.

**3. No Hetzner change needed** — port 80 already open from CHG-002.

**Test:**
```bash
curl https://smartdeliveryapi.rajanlabs.com/orderservice/api/diagnostics/chain
# Expected: 200 OK over HTTPS
```

**UI config after this step:**
```env
VITE_API_BASE_URL=https://smartdeliveryapi.rajanlabs.com
```

**Traffic flow after CHG-003:**
```
Browser
  → HTTPS → Cloudflare edge (cert managed by Cloudflare, free)
  → HTTP  → VPS port 80
  → nginx → localhost:30774
  → Istio IngressGateway → VirtualService → Pod
```

**Status:** 🔲 Not done yet

---

### CHG-004 — Enable Cloudflare proxy (orange cloud)

| Field | Detail |
|-------|--------|
| **Date** | TBD — after CHG-003 is Done |
| **Status** | 🔲 Planned |
| **Reason** | Adds DDoS protection, CDN caching, hides origin IP. Requires HTTPS (CHG-003) first. |
| **Action** | In Cloudflare DNS, flip `smartdeliveryapi` record from grey cloud → orange cloud. |

---

### CHG-006 — Domain migration to `rajanhub.com`, free-tier DB rescue, and CI/release repair

| Field | Detail |
|-------|--------|
| **Date** | 2026-09-01 |
| **Status** | ✅ Done |
| **Branch** | `feature/ps/chaos` (commits `a4a6f6f` … `b920a64`) |
| **Reason** | `rajanlabs.com` lapsed and was re-registered by a third party; the Azure SQL free allowance was being exhausted in ~55h; CI had been unable to reach the cluster since 2026-08-15. |

#### Part 1 — Kubeconfig renewal

The local kubeconfig failed with a 401, not an obvious TLS error. k3s had already rotated its
`client-admin` cert on the server (valid to 2027-04-18); only the local copy was stale, still
carrying the cert that expired 2026-08-15. No k3s restart was needed — it was a re-download:

```bash
ssh sd-master 'cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's#https://127.0.0.1:6443#https://46.62.150.44:6443#' > "$KUBECONFIG"
```

> `KUBECONFIG` points at `D:\dESKTOPBACKUP\Learn\kubeconfig - Copy`, **not** `~/.kube/config`.

**Verified:** both nodes `Ready`.

#### Part 2 — Domain migration `rajanlabs.com` → `rajanhub.com`

The old domain had been re-registered by someone else and resolved to a host outside our control
(`2.59.170.20`), so the deployed frontend was sending auth requests to a third party.

| Item | Change |
|---|---|
| Istio Gateway | host → `smartdeliveryapi.rajanhub.com` (:80, :443) |
| VirtualService | host + CORS origin → `smartdelivery.rajanhub.com` |
| Origin TLS cert | new Cloudflare Origin cert, SANs `*.rajanhub.com`, valid to 2041 |
| Frontend | `environment.prod.ts` rebuilt and redeployed to Azure SWA |
| Docs | INFRA_SPEC, OBSERVABILITY_ARCH, CHAOS_TESTING updated |

CHG-001…004 above deliberately retain the old hostname — they are dated records.

**Verified:** API `200` through Cloudflare; deployed bundle contains zero `rajanlabs` references;
CORS preflight from `https://smartdelivery.rajanhub.com` returns `200`.

#### Part 3 — Free-tier database burn (root cause)

All five databases hit the free allowance and paused. The cause was **not** external traffic — the
ingress gateway showed none. `/health/ready` included the SqlServer health check (tagged `"ready"`),
and the readiness probe ran every 15s across 4 services × 5 replicas = 20 pods = ~80 SQL logins per
minute, continuously. With `autoPauseDelay` at 60 minutes the databases never saw an idle window,
so they never paused and billed 0.5 vCore around the clock — ~55 hours to exhaust 100k vCore-sec.

> This is about **continuity, not volume**. One pod probing every 30 minutes prevents auto-pause
> just as effectively. Reducing replicas does not fix it.

Fixed in two layers:

- Manifests: `readinessProbe` → `/ping` (resolves no checks). Liveness already used `/health/live`.
- Source: dropped the `"ready"` tag from the SQL check in `HealthCheckExtensions.cs`, so
  `/health/ready` resolves to the `self` check only. The DB check still reports on `/health`.

Keep `freeLimitExhaustionBehavior: AutoPause` — that is what prevents surprise bills.

**Verified:** 2026-09-01, allowance renewed and all five databases reached `Paused` on their own.

#### Part 4 — CI credentials

The `KUBECONFIG` secret (last set 2026-03-02) predated the k3s cert rotation and had expired.
Replaced with a least-privilege `gha-deployer` service-account token rather than the admin cert:

```powershell
.\base\compose.ps1 -SetSecret
```

`compose.ps1` had three defects, each producing a secret that looked fine and failed later: it took
the CA from a service-account secret in `istio-system` (Istio's CA, not the k3s server CA — causing
`x509: certificate signed by unknown authority`), minted a 1-hour token, and wrote the credential to
disk. It now sources the CA from `kubectl config view --minify --raw`, requests 8760h, verifies the
kubeconfig can reach the cluster before storing it, and pipes straight to `gh secret set`.

`gha-deployer-role` existed only in the cluster and is now tracked in `base/gha.yaml`, with
`customresourcedefinitions: [get, list]` added — the release probes for the Istio CRD via
`if kubectl get crd ... 2>/dev/null`, so without it the VirtualService was silently skipped.

**Credential hygiene** (this repo is public): removed the `cat kubeconfig` debug step that printed
the credential into every run log; untracked `base/gha-kubeconfig.yaml`; gitignored `token.txt`,
`kubeconfig`, and the origin PEMs.

#### Part 5 — Release pipeline defects

| Defect | Fix |
|---|---|
| Omitting `build_run_id` set the literal tag `:latest`, which no build publishes — it rolled all five services onto year-old images lacking `/ping` and `/health/live` (both 404 → liveness killed them). The input described itself as *"optional - leave empty for latest"*, so the documented path was the dangerous one. | Resolve the newest **successful** run of the service's build workflow via `gh run list`. |
| Parallel releases share one Hetzner firewall rule; each opens port 6443 and closes it with `if: always()`, so the first to finish revoked API access from the rest mid-deploy. | Shared `concurrency: group: k3s-release`, `cancel-in-progress: false`. |
| A bad tag surfaced only as ImagePullBackOff *after* manifests were applied and the last good image reference overwritten. | `docker manifest inspect` before anything touches the cluster. |
| Manifests carried `image: ...:latest` as the CI placeholder. | Changed to `:REPLACED_BY_CI`, so a stray local apply fails with a self-explaining name. |

> Only the rolling update's own caution kept the API serving through this — old pods were never torn
> down because the new ones never became ready.

#### Part 6 — PaymentDb schema gap

`payment-service` returned `Invalid object name 'PaymentIntents'` (SQL error 208). The migration
`20260318192317_InitialCreate` creates that table but had never been applied: on the last migration
run (2026-07-09) the Payment step was **skipped**. Applied via the migration pipeline with only
`migrate_payment=true`.

This also explains why payment-service was the outlier throughout — no probes, 291 restarts over 16h.

#### Current state (verified 2026-09-01)

| Service | Image tag | Ready |
|---|---|---|
| auth-service | `33418089145` | 2/2 |
| cart-service | `33418097244` | 1/1 |
| order-service | `33418104912` | 1/1 |
| payment-service | `33418112520` | 3/3 |
| restaurent-service | `33418120293` | 1/1 |

All pods `2/2 Running`; API `200` via Cloudflare; all five databases `Paused` (auto-pause working).

#### Still open

1. Cloudflare SSL mode stays at **Full**, not Full (strict). The origin cert is correct, so the API
   alone could take strict — but the setting is zone-wide and `rajanhub.com` hosts other sites whose
   origins may not present valid certificates, which would start returning 526. Decided 2026-09-01:
   leave as is. The Cloudflare→origin leg is therefore encrypted but not authenticated. If this needs
   tightening later, do it per-hostname (Configuration Rules) rather than flipping the zone.
2. Revoke the old `rajanlabs` Cloudflare Origin certificate; delete the local `origin-*.pem`.
3. Admin access still depends on allow-listing a dynamic home IP. `base/update-my-ip.ps1` replaces
   the IP on rules it owns (unlike `open-firewall-port.ps1`, which appends and leaves stale entries),
   but the real fix is a tailnet on `sd-master` and closing 2222/6443 entirely.
4. `Restaurant`, `Order` and `Cart` migrations were also skipped on the 2026-07-09 run — verify their
   schemas match their migrations folders before a code path hits a missing table.
5. `Microsoft.OpenApi 2.4.1` carries a known high-severity advisory (GHSA-v5pm-xwqc-g5wc).
6. Seed credentials `admin/password123` and `testuser/password` are hardcoded in `AuthDbContext.cs`,
   and `appsettings.json` holds the SQL password and JWT signing key in plaintext.

---

## Pending / Future Changes

| ID | Description | Status |
|----|-------------|--------|
| CHG-002 | nginx reverse proxy: port 80 → 30774 | � Up next |
| CHG-003 | HTTPS via Let's Encrypt (certbot + nginx) | 🔲 Planned |
| CHG-004 | Enable Cloudflare proxy (orange cloud) after HTTPS | 🔲 Planned |
| CHG-005 | Set Istio mTLS to STRICT mode | 🔲 Future |
| CHG-006 | Domain migration to rajanhub.com, free-tier DB rescue, CI/release repair | ✅ Done |

---

## Current Cluster State (as of 2026-09-01)

| Component | State |
|-----------|-------|
| Nodes | `sd-master` 46.62.150.44 / 10.0.0.2, `sd-worker-0` 62.238.11.224 / 10.0.0.4 — both `Ready`, k3s v1.33.3 |
| Public API hostname | `smartdeliveryapi.rajanhub.com` (Cloudflare proxied → 46.62.150.44) |
| Frontend hostname | `smartdelivery.rajanhub.com` (CNAME → Azure SWA `smartdelivery-frontend`, DNS-only) |
| Gateway | `istio-system/istio-public-gateway` — :80 and :443, cred `smartdeliveryapi-tls` |
| Origin TLS cert | Cloudflare Origin, SANs `*.rajanhub.com` + `rajanhub.com`, expires 2041-08-27 |
| Cloudflare SSL mode | **Full** — not yet Full (strict); see CHG-006 "Still open" |
| IngressGateway NodePort | `30774` (HTTP), `31271` (HTTPS) |
| mTLS | Permissive (CHG-005 still future) |
| Readiness probe | `/ping` on all services — must never call SQL, see CHG-006 Part 3 |
| Liveness probe | `/health/live` |
| Databases | 5 on `smartdeliverypoc01`, serverless free tier, `AutoPause` on exhaustion |
| Cluster kubeconfig (local) | k3s admin cert, expires 2027-04-18 |
| CI credential | `gha-deployer` SA token in the `KUBECONFIG` repo secret, minted 2026-08-31 |
| Admin access | SSH 2222 + API 6443 allow-listed to a *dynamic* home IP — run `base/update-my-ip.ps1` when they time out |
| All 5 services | Running `2/2` on pinned image tags (see CHG-006) |
