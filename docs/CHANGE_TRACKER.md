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

## Pending / Future Changes

| ID | Description | Status |
|----|-------------|--------|
| CHG-002 | nginx reverse proxy: port 80 → 30774 | � Up next |
| CHG-003 | HTTPS via Let's Encrypt (certbot + nginx) | 🔲 Planned |
| CHG-004 | Enable Cloudflare proxy (orange cloud) after HTTPS | 🔲 Planned |
| CHG-005 | Set Istio mTLS to STRICT mode | 🔲 Future |

---

## Current Cluster State (as of 2026-03-08)

| Component | State |
|-----------|-------|
| Node IP | `46.62.150.44` |
| IngressGateway NodePort | `30774` |
| Gateway hostname | `api.smartdelivery.local` (pre CHG-001) |
| VirtualService hostname | `api.smartdelivery.local` (pre CHG-001) |
| Cloudflare DNS | `smartdeliveryapi.rajanlabs.com` → `46.62.150.44` ✅ Added |
| mTLS | Permissive |
| Firewall port 30774 | Must be open in Hetzner for external access |
| All 5 services | Running (`2/2` with Envoy sidecar) |
