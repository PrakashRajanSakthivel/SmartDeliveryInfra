# Phase 3 — Chaos Testing Runbook

Cluster: k3s (sd-master + sd-worker-0), Istio 1.25.2, mTLS Permissive  
Date started: 2026-04-28

---

## Overview

This phase validates mesh resilience using Istio-native fault injection — no extra tooling required.  
All experiments use `VirtualService` resources with a `chaos: "true"` label so they can be bulk-removed cleanly.

**Files:**

| File | Purpose |
|---|---|
| `release/chaos/payment-service-delay.yaml` | 5s HTTP delay on 100% of payment-service traffic |
| `release/chaos/order-service-abort.yaml` | HTTP 503 abort on 100% of order-service traffic |
| `release/chaos/chaos-runner.ps1` | Apply / remove experiments from the CLI |

---

## Pre-Chaos Checklist

Before each experiment, confirm the baseline:

```powershell
# All pods 2/2
kubectl get pods -n smartdelivery -o wide

# No active chaos VS
kubectl get virtualservice -n smartdelivery -l "chaos=true"
# Expected: No resources found

# Confirm k6 baseline passes (optional)
k6 run release/k6-load-test.js --duration 1m --vus 5
```

---

## Experiment 1 — Payment-Service HTTP Delay (5s)

### What it does
Instructs the Envoy sidecar inside every pod that calls `payment-service` to hold the connection for 5 seconds before forwarding the response. The upstream pod is never hit until after the delay.

### Apply
```powershell
.\release\chaos\chaos-runner.ps1 -Experiment delay
# or directly:
kubectl apply -f release/chaos/payment-service-delay.yaml
```

### What to observe

**Jaeger** (`localhost:16686` after port-forward):
- Search service: `payment-service` → look for spans with duration > 5s
- Parent spans from `order-service` or `cart-service` calling payment will also show inflated duration

**Grafana** (`localhost:3000`):
- Panel: "Request Duration p95 by Service" → PaymentService line spikes to ≥ 5s
- Panel: "HTTP Error Rate" → should stay 0% (delay, not failure)

**k6 — run during the experiment:**
```powershell
k6 run release/k6-load-test.js --duration 2m --vus 10
```
Expected: `http_req_duration` p95 climbs. If PaymentService has no internal timeout, the full checkout flow may time out at the gateway (504).

### Remove
```powershell
.\release\chaos\chaos-runner.ps1 -Cleanup
```

### Results — 2026-04-28 (k6: 2m, 10 VUs)

| Metric | Baseline (Phase 2) | With 5s Delay |
|---|---|---|
| http_req_duration p95 | 2,410 ms | 4,630 ms (+92%) |
| checkout_full_flow_ms p95 | — | 55,720 ms (11× over 5s threshold) |
| checkout_full_flow_ms max | — | 68,000 ms |
| http_req_failed rate | 24.71% | 25.90% (no change — Azure SQL) |
| order_errors | 0.00% | 0.00% |
| Iterations completed | 555 | 66 (-88% — VUs blocked on 55s payment calls) |
| Jaeger traces > 5s | No | Yes — 55s+ spans on every payment call |
| Kiali edge colour | Green | Orange (slow) |
| Recovery time after cleanup | — | Immediate (<5s Envoy propagation) |

**Finding:** The 5s Istio delay stacked on top of Azure SQL serverless cold-start (~50s),
producing 55s end-to-end payment traces. The delay itself is confirmed working — the extra
50s is a pre-existing Azure SQL vulnerability now exposed under pressure. Failure rate
did not increase (still ~25%) but throughput collapsed 88% because VUs were blocked.

**Action item:** Add Azure SQL warm-up (cron or health-ping) before running clean chaos tests.

---

## Experiment 2 — Order-Service HTTP Abort (503)

### What it does
Instructs the Envoy sidecar to immediately return an HTTP 503 for every request to `order-service`, without ever forwarding to the upstream pod. The pod itself receives zero traffic.

### Apply
```powershell
.\release\chaos\chaos-runner.ps1 -Experiment abort
# or directly:
kubectl apply -f release/chaos/order-service-abort.yaml
```

### What to observe

**Kiali** (`localhost:20001`):
- Graph view → `smartdelivery` namespace
- Red error badge on the `order-service` node
- Edges inbound to order-service turn red with `503` label

**Grafana**:
- Panel: "HTTP Error Rate" → OrderService line goes to 100%
- Panel: "Request Rate" → inbound to order-service stays at 0 RPS (Envoy short-circuits)

**Jaeger**:
- Traces for `order-service` show `http.status_code=503` on the first span
- Duration is near-zero (aborted before ever hitting the app)

**k6 — run during the experiment:**
```powershell
k6 run release/k6-load-test.js --duration 2m --vus 10
```
Expected: All order-creation steps fail immediately. `order_errors` counter in k6 should go to 100%.

### Remove
```powershell
.\release\chaos\chaos-runner.ps1 -Cleanup
```

### Results — 2026-05-01 (k6: 2m, 10 VUs)

| Metric | Baseline (Phase 2) | With 503 Abort |
|---|---|---|
| order_errors rate | 0.00% | **100.00%** (120/120) |
| order created 2xx | 100% | **0%** (0/120) |
| http_req_duration p95 | 2,410 ms | **2,270 ms** (lower — fast fail) |
| http_req_duration max | — | 9,630 ms (Azure SQL on payment, not order) |
| http_req_failed rate | 24.71% | **37.60%** (all orders fail) |
| Iterations completed | 555 | **120** (+82% vs Exp 1's 66 — VUs freed fast) |
| Order-service pod requests | normal | **zero** — pod shielded entirely |
| Kiali order-service workload | green | **green** (pod idle, fault at Envoy) |
| Kiali gateway→service edge | green | **red** (503 recorded at Service node) |
| Recovery time after revert | — | Immediate (<5s Envoy propagation) |

**Finding:** 100% of order creations returned 503. The order-service pod received zero
traffic — the abort fired at the IngressGateway Envoy before forwarding.
Counterintuitively, throughput was *higher* than Experiment 1 (120 vs 66 iterations)
because VUs failed fast and moved on, rather than blocking for 55s on a slow payment.

**Key lesson:** Fast-fail is better for system throughput than slow-fail. A service that
returns 503 immediately causes less cascading damage than one that hangs.

**Implementation note:** Fault must be injected in the main gateway VirtualService
(`smartdelivery-vs`), not a separate chaos VS targeting the internal FQDN — the
IngressGateway only looks at `hosts: [smartdeliveryapi.rajanlabs.com]`.

---

## Experiment 3 — Pod Deletion (Self-Healing)

### What it does
Deletes a random pod in the `smartdelivery` namespace. Kubernetes reschedules it; the experiment measures how long until it returns to `2/2 Running`.

### Run
```powershell
.\release\chaos\chaos-runner.ps1 -Experiment pod-kill
```

### What to observe

**kubectl watch** (separate terminal):
```powershell
kubectl get pods -n smartdelivery -w
```
Watch the deleted pod transition: `Terminating` → gone → new pod `0/2 ContainerCreating` → `1/2` → `2/2 Running`.

**Grafana**:
- Kube-state-metrics panel: pod restart count increments
- If HPA is active, check whether it reschedules on the other node (cross-node scheduling)

**Expected recovery time**: 20–60s depending on image pull and sidecar injection.

### Results (fill in after running)

| Item | Value |
|---|---|
| Pod deleted | ___ |
| Node it was on | ___ |
| Node it rescheduled to | ___ |
| Time to `2/2 Running` | ___ s |
| Traffic interruption observed? | Yes / No |

---

## Experiment 4 — Combined (all faults simultaneously)

Run delay + abort together to simulate cascading failure:

```powershell
.\release\chaos\chaos-runner.ps1 -Experiment all
```

Run k6 during to observe the compound effect:
```powershell
k6 run release/k6-load-test.js --duration 2m --vus 15
```

Observe how upstream services behave when both payment and order are degraded simultaneously.

### Cleanup
```powershell
.\release\chaos\chaos-runner.ps1 -Cleanup
```

---

## Post-Chaos Verification

After every experiment clean up and re-verify:

```powershell
# No chaos VirtualServices remain
kubectl get virtualservice -n smartdelivery -l "chaos=true"
# Expected: No resources found

# All pods healthy
kubectl get pods -n smartdelivery -o wide
# Expected: all 2/2 Running

# Spot-check an actual request
curl -s -o /dev/null -w "%{http_code}" https://smartdeliveryapi.rajanlabs.com/healthz
# Expected: 200
```

---

## Key Learnings (fill in after experiments)

- 
- 
- 
