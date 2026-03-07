# Issue: Istio VirtualService `rewrite` Instruction Ignored — 404 from Order Service

**Date Resolved:** March 7, 2026  
**Affected Component:** Istio Ingress Gateway → OrderService  
**Environment:** k3s + Istio service mesh  

---

## Problem Statement

The Istio Ingress Gateway was correctly routing traffic to `order-service` based on the path prefix `/orderservice/`. However, the `rewrite` instruction in the VirtualService was being ignored. As a result, the backend `order-service` received the full path `/orderservice/api/diagnostics/chain` instead of the expected `/api/diagnostics/chain`, causing a **404 Not Found** from the application.

---

## Symptoms

- `curl -H "Host: api.smartdelivery.local" http://<gateway>/orderservice/api/diagnostics/chain` → **404**
- Direct `kubectl port-forward` to `order-service` + `curl /api/diagnostics/chain` → **200 OK**
- Application logs showed request path: `/orderservice/api/diagnostics/chain` (prefix NOT stripped)

---

## Diagnosis Steps

| Step | Action | Expected | Actual | Conclusion |
|------|--------|----------|--------|------------|
| 1 | curl via Ingress Gateway | 200 OK | 404 Not Found | Traffic reaches gateway but fails at backend |
| 2 | curl directly to order-service via port-forward | 200 OK | 200 OK | Service is healthy, listens on `/api/...` |
| 3 | Updated VirtualService with prefix `/orderservice` + rewrite `/` | 200 OK | 404 Not Found | Config syntactically correct but behavior persists |
| 4 | Checked order-service application logs | Path: `/api/diagnostics/chain` | Path: `/orderservice/api/diagnostics/chain` | Confirmed rewrite failure — Istio did NOT strip prefix |
| 5 | Moved OrderService route to top of VirtualService | 200 OK | 404 Not Found | Rule ordering is not the issue |
| 6 | Hardcoded rewrite to fixed string | 200 OK | 404 Not Found | Even explicit rewrites were ignored |
| 7 | Created VirtualService in `istio-system` namespace | 200 OK | 404 Not Found | Namespace boundaries not the cause |
| 8 | Checked for conflicting EnvoyFilter/VirtualService resources | Clean state | Clean state | No external interference |

---

## Root Cause Investigation

### Step 1 — Inspected Envoy's live xDS route config

```powershell
kubectl exec -n istio-system deployment/istio-ingressgateway -- `
  curl -s http://localhost:15000/config_dump | `
  Select-String -Pattern "orderservice|prefixRewrite|rewrite" -Context 2
```

**Finding:** The rewrite rule **WAS present** in Envoy's config:
```json
"prefix": "/orderservice",
"prefix_rewrite": "/"
```

This ruled out a sync/version issue. The config was reaching Envoy correctly.

### Step 2 — Checked path normalization settings

```powershell
kubectl exec -n istio-system deployment/istio-ingressgateway -- `
  curl -s http://localhost:15000/config_dump | `
  Select-String -Pattern "normalize|merge_slash|path_with_escaped" -Context 3
```

**Finding:**
```json
"normalize_path": true,
"path_with_escaped_slashes_action": "KEEP_UNCHANGED"
```

- `normalize_path: true` handles RFC 3986 normalization but does **not** merge double slashes.
- **`merge_slashes` was absent** — double slashes are passed through unchanged.

---

## Root Cause

The prefix match `/orderservice` (no trailing slash) combined with `prefix_rewrite: /` produced a **double slash**:

```
/orderservice/api/diagnostics/chain
    ↓ strip "/orderservice", prepend "/"
//api/diagnostics/chain   ← double slash!
```

Since `merge_slashes` was not configured, Envoy forwarded `//api/diagnostics/chain` to the backend. The ASP.NET Core (Kestrel) application did not recognize `//api/diagnostics/chain` as a valid route → **404**.

---

## Fix

Added a **trailing slash** to all prefix matches in the VirtualService. This ensures Envoy replaces `/orderservice/` with `/`, producing a clean single-slash path.

**File:** `release/RestaurentService/smartdelivery-virtualservice.yaml`

**Before:**
```yaml
- match:
  - uri:
      prefix: /orderservice
  rewrite:
    uri: /
```

**After:**
```yaml
- match:
  - uri:
      prefix: /orderservice/
  rewrite:
    uri: /
```

The same trailing-slash fix was applied to all service routes: `/restaurentservice/`, `/paymentservice/`, `/cartservice/`, `/authservice/`.

---

## Verification

```powershell
curl -v -H "Host: api.smartdelivery.local" http://localhost:8080/orderservice/api/diagnostics/chain
```

**Response:**
```
HTTP/1.1 200 OK
server: istio-envoy
x-envoy-upstream-service-time: 25

{"service":"OrderService","host":"order-service-86669dcbc9-rhpwv",...,
 "downstream":{"service":"RestaurantService",...}}
```

- `server: istio-envoy` confirms traffic went through the Istio ingress gateway
- `x-envoy-upstream-service-time` confirms Envoy processed and rewrote the path
- Full diagnostic chain (OrderService → RestaurantService) returned successfully

---

## Key Lessons

1. **Always inspect Envoy's live config first** (`/config_dump` via admin port 15000) before assuming a config sync problem. It immediately shows whether rewrite fields are present.
2. **Trailing slash matters on prefix rewrites.** `prefix: /foo` + `rewrite: /` → `//bar`. Use `prefix: /foo/` + `rewrite: /` → `/bar`.
3. **Stale port-forwards cause misleading test results.** Always verify which service a port is actually forwarded to (`netstat -ano` + `Get-Process`) before interpreting curl results.
4. `normalize_path: true` in Envoy does NOT collapse `//` — that requires `merge_slashes: true` on the `HttpConnectionManager`.
