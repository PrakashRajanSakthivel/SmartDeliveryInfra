# Blog Post — Phase 3: Chaos Testing SmartDelivery with Istio Fault Injection

*LinkedIn post draft. References previous two posts.*

---

**I intentionally broke my production-like cluster with Istio chaos. Here's what actually happened.**

In post 1, I built SmartDelivery — 5 .NET 8 microservices — on raw k3s to understand what AKS quietly handles for you.
In post 2, I added a worker node and spent a full day debugging Flannel VXLAN asymmetric routing.

This week: Phase 3. Chaos Testing.

No extra tooling. No Chaos Monkey. No new deployments.
Just Istio VirtualService fault injection — already in the cluster.

---

**Experiment 1 — Inject a 5 second delay into payment-service**

4 lines of YAML:

```yaml
fault:
  delay:
    fixedDelay: 5s
    percentage:
      value: 100
```

Apply. Run k6. Watch Jaeger.

What I expected: payment traces showing 5s spans.
What I got: 55 second traces.

The 5s Istio delay triggered Azure SQL serverless cold-start.
The DB had auto-paused. Connection pool exhaustion added ~50s on top.
Throughput dropped 88%. 66 iterations completed vs 555 baseline.

The delay didn't cause new failures. It just exposed a vulnerability that was already there — silently — at low traffic.

Kiali showed the payment-service edge turn orange.
Jaeger showed every payment span sitting at 55s+.
The pod was fine. The database was the problem.

---

**Experiment 2 — Inject a 503 abort into order-service**

Same idea. Different result.

```yaml
fault:
  abort:
    httpStatus: 503
    percentage:
      value: 100
```

Apply. Run k6.

order_errors: 100%. Every single order creation failed instantly.
But here's the counterintuitive part:

Throughput was HIGHER than the delay experiment.
120 iterations vs 66.
p95 latency DROPPED from 4.6s to 2.3s.

Because fast-fail frees virtual users immediately.
A 503 takes <5ms. A 5s delay holds a VU hostage for 55s.

Kiali showed something interesting too.
The order-service SERVICE node (triangle) went red.
The order-service WORKLOAD node (circle) stayed green.

The pod received zero traffic. Envoy aborted at the gateway before forwarding a single request. The pod was completely shielded.

---

**The thing that tripped me up**

Fault injection on a VirtualService with only `hosts: [service.namespace.svc.cluster.local]` defaults to the `mesh` gateway.

That means it applies to sidecar-to-sidecar calls only.
Traffic coming from the IngressGateway bypasses it entirely.

I spent time wondering why order-service was green after applying the chaos VS.
The fix: inject the fault into the main gateway VirtualService — the one that actually handles external traffic.

AKS abstracts this. On raw Istio you learn it the hard way.

---

**What chaos testing actually tells you**

❌ It does NOT tell you Kubernetes self-heals pods. (Every cluster does that. Not worth testing.)

✅ It DOES tell you:
- Which services have no timeout configured (payment-service — stacked 55s)
- Which services fail gracefully vs which drag everything down
- Whether your observability actually catches it (Jaeger, Kiali, Grafana — all caught it)
- That fast-fail is kinder to system throughput than slow-fail

---

**Stack:**
k3s · Istio 1.25.2 · Flannel VXLAN · .NET 8 · Azure SQL serverless · k6 · Jaeger · Kiali · Grafana

Post 1 (what AKS hides from you): https://lnkd.in/gwvpfCym
Post 2 (adding a worker node): https://lnkd.in/gfHS8mmF

#kubernetes #istio #chaostesting #dotnet #k3s #devops #microservices #observability #servicemesh
