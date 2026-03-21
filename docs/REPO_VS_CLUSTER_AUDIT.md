# SmartDelivery — Repo vs Cluster Configuration Audit

> **Purpose:** Full diff of every values file in `Smart/` and `release/` against what is actually running in the cluster. Use this as the single source of truth for migration to a new hosting provider.
> **Audited:** 2026-03-21 | **Cluster:** k3s v1.33.3 on sd-master (46.62.150.44)

---

## Key Finding — Installation Method

Helm release secrets only exist in `kube-system`. Here is the actual installation method
per component along with the reason for each choice:

| Component | Namespace | Installed Via | Helm State Exists? |
|---|---|---|---|
| istiod | `istio-system` | `helm install` individual chart + **post-install resource patch** | ❌ No secret — Helm state lost/reset |
| istio-ingressgateway | `istio-system` | `helm install` individual chart + **post-install resource patch** | ❌ No secret — Helm state lost/reset |
| istio-egressgateway | `istio-system` | `helm install` individual chart + **post-install resource patch** | ❌ No secret — Helm state lost/reset |
| grafana | `istio-system` | `kubectl apply` from Istio addon manifest + **post-install resource patch** | ❌ Not Helm-managed |
| prometheus | `istio-system` | `kubectl apply` from Istio addon manifest + **post-install resource patch** | ❌ Not Helm-managed |
| jaeger | `istio-system` | `kubectl apply` from Istio addon manifest | ❌ Not Helm-managed |
| kiali | `istio-system` | `kubectl apply` from Istio addon manifest | ❌ Not Helm-managed |
| elasticsearch | `logging` | `kubectl apply` — manifest in `release/logging/elasticsearch.yaml` | ❌ Not Helm-managed |
| kibana | `logging` | `kubectl apply` — manifest in `release/logging/kibana.yaml` | ❌ Not Helm-managed |
| headlamp | `kube-system` | `helm install` | ✅ Secret in kube-system |
| kube-state-metrics | `kube-system` | `helm install` (2026-03-21) | ✅ Secret in kube-system |
| node-exporter | `kube-system` | `helm install` (2026-03-21) | ✅ Secret in kube-system |
| traefik / traefik-crd | `kube-system` | k3s built-in Helm | ✅ Secret in kube-system |

**Why Helm state is missing for Istio components:** The initial install was done with the
standard `helm install` flow, but the Helm state was lost at some point (likely a
namespace recreation or uninstall/reinstall cycle during the resource-reduction work).
The Helm chart labels are preserved on all Istio objects, confirming the chart install
origin. The `values.yaml` files in `Smart/` are the only preserved record.

**Why resources were patched:** All Istio components + addons were installed with default
values first to confirm everything worked. After validation, resources were reduced via
`kubectl patch` to free RAM on the single-node VPS. The patched values are now captured
in the `Smart/` values files so they can be passed at install time on a new provider.

**Prometheus/Grafana history:** A separate Prometheus + Grafana stack was originally
running at cluster level (outside `istio-system`). It was deleted because it was redundant
with the Istio-bundled versions and consuming significant RAM. The Istio-bundled instances
now serve cluster-wide via `kubernetes_sd_configs` scrape jobs. A future migration to a
standalone cluster-wide Helm deployment is planned but deferred — it is a breaking change
(datasource URLs, dashboard variables, GHA monitoring pipeline).

> **Migration implication:** For istiod, gateways, grafana, prometheus, jaeger, kiali,
> elasticsearch, and kibana you cannot do `helm get values` — the `Smart/` and
> `release/logging/` files are the only record. This audit is the migration runbook.

---

## 1. istiod (`Smart/istiod-values.yaml`)

### Repo File
```yaml
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

meshConfig:
  accessLogFile: /dev/stdout
  enablePrometheusMerge: true
  defaultConfig:
    tracing:
      sampling: 100
  defaultProviders:
    metrics: [prometheus]
    tracing: [jaeger]
  extensionProviders:
  - name: jaeger
    opentelemetry:
      port: 4317
      service: jaeger-collector.istio-system.svc.cluster.local

global:
  proxy:
    autoInject: enabled
  logAsJson: false

pilot:
  autoscaleEnabled: false
  replicaCount: 1
```

### Live Cluster (verified `kubectl get deployment istiod`)
```
image    : docker.io/istio/pilot:1.25.2
replicas : 1
requests : cpu=10m  memory=100Mi   ← DIFFERENT from repo
limits   : (none set)              ← DIFFERENT from repo
```

### Live meshConfig (from `kubectl get configmap istio -n istio-system`)
```yaml
accessLogFile: /dev/stdout
enablePrometheusMerge: true
defaultConfig:
  discoveryAddress: istiod.istio-system.svc:15012
  tracing:
    sampling: 100
defaultProviders:
  metrics: [prometheus]
  tracing: [jaeger]
extensionProviders:
- name: otel                 # auto-added by Helm chart defaults — not explicitly configured
  envoyOtelAls:
    port: 4317
    service: opentelemetry-collector.observability.svc.cluster.local
- name: skywalking           # auto-added by Helm chart defaults — not explicitly configured
  skywalking:
    port: 11800
    service: tracing.istio-system.svc.cluster.local
- name: otel-tracing         # auto-added by Helm chart defaults — not explicitly configured
  opentelemetry:
    port: 4317
    service: opentelemetry-collector.observability.svc.cluster.local
- name: jaeger               # ✅ explicitly configured
  opentelemetry:
    port: 4317
    service: jaeger-collector.istio-system.svc.cluster.local
rootNamespace: istio-system
trustDomain: cluster.local
```

### Deviations

| Field | Repo | Live Cluster | Severity |
|---|---|---|---|
| `resources.requests.cpu` | `250m` | `10m` | ⚠️ Medium — cluster runs lighter |
| `resources.requests.memory` | `256Mi` | `100Mi` | ⚠️ Medium — cluster runs lighter |
| `resources.limits` | `cpu:500m mem:512Mi` | **not set** | ⚠️ Medium — no limits in cluster |
| `extensionProviders` | jaeger only | otel + skywalking + otel-tracing + jaeger | ℹ️ Low — extra providers, unused |

---

## 2. istio-ingressgateway / egressgateway (`Smart/gateway-values.yaml`)

### Repo File
```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

autoscaleEnabled: false
replicaCount: 1
```

### Live Cluster
```
ingressgateway: replicas=1  requests=cpu:10m mem:40Mi  limits=cpu:2  mem:1Gi
egressgateway : replicas=1  requests=cpu:10m mem:40Mi  limits=cpu:2  mem:1Gi
```

### Deviations

| Field | Repo | Live Cluster | Severity |
|---|---|---|---|
| `resources.requests.cpu` | `100m` | `10m` | ⚠️ Medium |
| `resources.requests.memory` | `128Mi` | `40Mi` | ⚠️ Medium |
| `resources.limits.cpu` | `200m` | `2` (cores) | ⚠️ Medium — live limit is 10× higher |
| `resources.limits.memory` | `256Mi` | `1Gi` | ⚠️ Medium — live limit is 4× higher |

---

## 3. istio-base (`Smart/istio-base-values.yaml`)

### Repo File
```yaml
global:
  proxy:
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
meshConfig:
  defaultConfig:
    concurrency: 1
telemetry:
  enabled: false
sidecarInjectorWebhook:
  enabled: true
```

### Live Cluster (Envoy sidecar actual usage)
```
Actual per-sidecar: ~33–42 MiB RAM, ~4–6m CPU
```

### Deviations

| Field | Repo | Live Cluster | Severity |
|---|---|---|---|
| `telemetry.enabled` | `false` | Telemetry resources exist (`release/istio-observability.yaml`) | ⚠️ Conflict — telemetry IS working via CRD, not base chart |
| Proxy resource requests | `cpu:100m mem:128Mi` | Not enforced at this level — sidecars use mesh-level defaults | ℹ️ Low |

---

## 4. Grafana (`Smart/grafana-values.yaml`)

### Repo File (after fix on 2026-03-21)
```yaml
service:
  type: ClusterIP
adminPassword: "admin"
datasources:
  datasources.yaml:
    datasources:
      - name: Prometheus
        url: http://prometheus:9090
        ...
      - name: Loki
        url: http://loki:3100
        ...
```

### Live Cluster
```
image    : docker.io/grafana/grafana:11.3.1
resources: requests=cpu:100m mem:128Mi  limits=cpu:200m mem:256Mi
service  : ClusterIP :3000
```

### Deviations

| Field | Repo | Live Cluster | Severity |
|---|---|---|---|
| `resources` | not in values file | `req: cpu:100m/mem:128Mi  lim: cpu:200m/mem:256Mi` | ℹ️ Low — cluster values came from istio addon manifest |
| `service.type` | `ClusterIP` ✅ (fixed) | `ClusterIP` | ✅ Now matches |
| `datasources` | Prometheus + Loki ✅ (fixed) | Prometheus + Loki | ✅ Now matches |
| Installation method | Described as Helm | Actually `kubectl apply` from addon | ℹ️ Documented above |

> **Note:** Grafana was applied via `Smart/istio-addons.yaml` (`kubectl apply`), not via `helm install grafana grafana/grafana`. The values file in `Smart/` is used **only as documentation / re-apply reference** and must be manually translated to a manifest addition if you need to reproduce.

---

## 5. Prometheus (`Smart/prometheus-values.yaml`)

### Repo File
```yaml
server:
  persistentVolume:
    enabled: false
  resources:
    limits:
      memory: 1Gi
      cpu: 500m
    requests:
      memory: 512Mi
      cpu: 250m
alertmanager:
  enabled: false
pushgateway:
  enabled: false
nodeExporter:
  enabled: false
```

### Live Cluster
```
image    : prom/prometheus (Istio-bundled, part of istio/prometheus addon)
resources: requests=cpu:10m mem:40Mi  limits=cpu:2 mem:1Gi
```

### Deviations

| Field | Repo File | Live Cluster | Severity |
|---|---|---|---|
| Installation method | Described as `prometheus-community/prometheus` Helm chart | Actually Istio addon (`kubectl apply`) | 🔴 **Critical for migration** |
| `resources.requests.cpu` | `250m` | `10m` | ⚠️ Medium |
| `resources.requests.memory` | `512Mi` | `40Mi` | ⚠️ Medium |
| `resources.limits.cpu` | `500m` | `2` cores | ⚠️ Medium |
| `resources.limits.memory` | `1Gi` | `1Gi` | ✅ Matches |
| Config (scrape jobs, alertrules) | Not in values file | Full scrape config in `ConfigMap/prometheus` in `istio-system` | 🔴 **Not in repo** |

> **Migration note:** The Prometheus scrape config (all `kubernetes_sd_configs` jobs) lives in `ConfigMap/prometheus` in `istio-system`. It is NOT in any repo file. **Export it before migrating:**
> ```powershell
> kubectl get cm prometheus -n istio-system -o yaml > Smart/prometheus-configmap-live.yaml
> ```

---

## 6. istio-addons (`Smart/istio-addons.yaml`)

### Repo File describes:
```yaml
kiali:    resources: req=cpu:100m/mem:128Mi  lim=cpu:200m/mem:256Mi
tracing:  resources: req=cpu:100m/mem:256Mi  lim=cpu:200m/mem:512Mi
prometheus: resources: req=cpu:100m/mem:128Mi  lim=cpu:200m/mem:256Mi
grafana:  resources: req=cpu:100m/mem:128Mi  lim=cpu:200m/mem:256Mi
```

### Live Cluster
```
jaeger   : image=jaegertracing/all-in-one:1.63.0  req=cpu:100m/mem:256Mi  lim=cpu:200m/mem:512Mi
kiali    : image=quay.io/kiali/kiali:v2.5          req=cpu:100m/mem:128Mi  lim=cpu:200m/mem:256Mi
prometheus: Istio's own image                      req=cpu:10m/mem:40Mi    lim=cpu:2/mem:1Gi
grafana  : grafana/grafana:11.3.1                  req=cpu:100m/mem:128Mi  lim=cpu:200m/mem:256Mi
```

### Deviations

| Component | Field | Repo | Live | Severity |
|---|---|---|---|---|
| kiali | resources | req:100m/128Mi lim:200m/256Mi | req:100m/128Mi lim:200m/256Mi | ✅ Matches |
| jaeger | resources | req:100m/256Mi lim:200m/512Mi | req:100m/256Mi lim:200m/512Mi | ✅ Matches |
| kiali | version | not pinned | `v2.5` | ℹ️ Low |
| jaeger | version | not pinned | `1.63.0` | ℹ️ Low |
| grafana | version | not pinned | `11.3.1` | ℹ️ Low |
| prometheus | resources | req:100m/128Mi lim:200m/256Mi | req:10m/40Mi lim:2cpu/1Gi | ⚠️ Medium — limits diverged significantly |

---

## 7. Elasticsearch (`Smart/elasticsearch-values.yaml`)

### Repo File

> `Smart/elasticsearch-values.yaml` was a shell script (not a Helm values file).
> It has been replaced with a redirect comment pointing to the proper manifest.
> The manifest is now at `release/logging/elasticsearch.yaml`.

### Live Cluster
```
image    : docker.elastic.co/elasticsearch/elasticsearch:8.15.0
requests : cpu=500m  memory=1Gi
limits   : cpu=1     memory=1536Mi    ← DIFFERENT from embedded manifest (1.5Gi = 1536Mi)
env      : discovery.type=single-node
           xpack.security.enabled=false
           ES_JAVA_OPTS=-Xms512m -Xmx512m
           cluster.name=elasticsearch
storage  : emptyDir (ephemeral)
service  : ClusterIP :9200 :9300
```

### Embedded Manifest in Repo File
```
limits   : cpu=1000m  memory=1.5Gi
service  : ClusterIP  (correct)
```

### Deviations

| Field | Repo Script Manifest | Live Cluster | Severity |
|---|---|---|---|
| `limits.memory` | `1.5Gi` (1536 MiB) | `1536Mi` | ✅ Same value, different notation |
| `limits.cpu` | `1000m` | `1` | ✅ Same value, different notation |
| File format | Shell script → converted to YAML | `release/logging/elasticsearch.yaml` | ✅ Fixed |

---

## 8. Kibana (`Smart/kibana-values.yaml`)

### Repo File

> `Smart/kibana-values.yaml` was a shell script (not a Helm values file).
> It has been replaced with a redirect comment pointing to the proper manifest.
> The manifest is now at `release/logging/kibana.yaml`.

### Live Cluster
```
image    : docker.elastic.co/kibana/kibana:8.15.0
requests : cpu=500m  memory=512Mi
limits   : cpu=1     memory=1Gi
env      : ELASTICSEARCH_HOSTS=http://elasticsearch:9200
           XPACK_SECURITY_ENABLED=false
           (all xpack.* features disabled)
service  : NodePort :5601 → 30601
```

### Deviations

| Field | Repo Script Manifest | Live Cluster | Severity |
|---|---|---|---|
| Resources | req:500m/512Mi lim:1000m/1Gi | req:500m/512Mi lim:1/1Gi | ✅ Matches |
| Service type | NodePort :30601 | NodePort :30601 | ✅ Matches |
| File format | Shell script → converted to YAML | `release/logging/kibana.yaml` | ✅ Fixed |

---

## 9. Headlamp (`Smart/headlamp-values.yaml`)

### Repo File
```yaml
service:
  type: NodePort
  nodePort: 30900
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 150m
    memory: 128Mi
persistentVolumeClaim:
  enabled: false
```

### Live Cluster (Helm-managed)
```
image    : ghcr.io/headlamp-k8s/headlamp:v0.40.0
requests : cpu=50m  memory=64Mi
limits   : cpu=150m memory=128Mi
service  : NodePort :30900
```

### Deviations

| Field | Repo | Live | Severity |
|---|---|---|---|
| All resource settings | — | — | ✅ **Fully matches** |
| Service type & nodePort | NodePort :30900 | NodePort :30900 | ✅ **Fully matches** |

---

## 10. New Components (added 2026-03-21, not yet in repo values)

### kube-state-metrics (installed today)
```
chart  : prometheus-community/kube-state-metrics 7.2.1 (app: 2.18.0)
ns     : kube-system
config : requests=cpu:10m/mem:32Mi  limits=cpu:50m/mem:64Mi
```
> **Gap:** No values file exists in `Smart/` yet.

### node-exporter (installed today)
```
chart  : prometheus-community/prometheus-node-exporter 4.52.1 (app: 1.10.2)
ns     : kube-system
config : requests=cpu:10m/mem:20Mi  limits=cpu:50m/mem:32Mi
```
> **Gap:** No values file exists in `Smart/` yet.

---

## Summary — Deviation Severity Matrix

| Component | File | Deviations | Severity | Status |
|---|---|---|---|---|
| istiod | `Smart/istiod-values.yaml` | Resources were chart defaults, not the patched live values | ⚠️ Medium | ✅ Fixed 2026-03-21 — live patched values now in file |
| ingressgateway | `Smart/gateway-values.yaml` | Same — chart defaults, not patched live values | ⚠️ Medium | ✅ Fixed 2026-03-21 |
| egressgateway | `Smart/gateway-values.yaml` | Same | ⚠️ Medium | ✅ Fixed 2026-03-21 |
| Prometheus | `Smart/prometheus-values.yaml` | Wrong chart type documented, wrong install method, scrape config not in repo | 🔴 Critical | ✅ Rewritten 2026-03-21 — reflects current addon install + future migration note |
| Grafana | `Smart/grafana-values.yaml` | datasources:[], NodePort | ✅ Fixed | ✅ Fixed 2026-03-21 |
| Elasticsearch | `Smart/elasticsearch-values.yaml` | Was a shell script | ⚠️ Medium | ✅ Fixed 2026-03-21 — manifest at `release/logging/elasticsearch.yaml` |
| Kibana | `Smart/kibana-values.yaml` | Was a shell script | ⚠️ Medium | ✅ Fixed 2026-03-21 — manifest at `release/logging/kibana.yaml` |
| Headlamp | `Smart/headlamp-values.yaml` | Fully matched | ✅ Good | ✅ No change needed |
| kube-state-metrics | `Smart/kube-state-metrics-values.yaml` | File did not exist | ⚠️ Medium | ✅ Created 2026-03-21 |
| node-exporter | `Smart/node-exporter-values.yaml` | File did not exist | ⚠️ Medium | ✅ Created 2026-03-21 |
| istio-base | `Smart/istio-base-values.yaml` | `telemetry.enabled: false` conflicts with working telemetry | ⚠️ Medium | Clarify in file |

---

## Migration Runbook (New Provider)

Use this order to reproduce the full cluster on a fresh k3s node:

```
1.  Install k3s

2.  # Istio — individual Helm charts with resource-constrained values
    helm repo add istio https://istio-release.storage.googleapis.com/charts
    helm repo update
    helm install istio-base istio/base -n istio-system --create-namespace \
      -f Smart/istio-base-values.yaml
    helm install istiod istio/istiod -n istio-system \
      -f Smart/istiod-values.yaml
    helm install istio-ingressgateway istio/gateway -n istio-system \
      -f Smart/gateway-values.yaml
    helm install istio-egressgateway istio/gateway -n istio-system \
      -f Smart/gateway-values.yaml

3.  # Istio addons — kubectl apply (grafana, prometheus, kiali, jaeger)
    kubectl apply -f Smart/istio-addons.yaml

4.  # Istio gateway config
    kubectl apply -f istio-gateway-config.yaml

5.  # Application namespaces and secrets
    kubectl apply -f release/namespace.yaml
    kubectl apply -f release/image-pull-secret.yaml
    kubectl apply -f release/istio-observability.yaml

6.  # Application workloads
    kubectl apply -f release/AuthService/
    kubectl apply -f release/CartService/
    kubectl apply -f release/OrderService/
    kubectl apply -f release/PaymentService/
    kubectl apply -f release/RestaurentService/

7.  # Logging stack
    kubectl apply -f release/logging/namespace.yaml
    kubectl apply -f release/logging/elasticsearch.yaml
    kubectl apply -f release/logging/kibana.yaml

8.  # Cluster observability (Helm)
    helm repo add headlamp https://headlamp-k8s.github.io/headlamp/
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    helm install headlamp headlamp/headlamp -n kube-system \
      -f Smart/headlamp-values.yaml
    helm install kube-state-metrics prometheus-community/kube-state-metrics \
      -n kube-system -f Smart/kube-state-metrics-values.yaml
    helm install node-exporter prometheus-community/prometheus-node-exporter \
      -n kube-system -f Smart/node-exporter-values.yaml

9.  # TLS secret for ingress
    kubectl create secret tls smartdeliveryapi-tls \
      --cert=<path-to-cert> --key=<path-to-key> -n istio-system

10. # Virtual service
    kubectl apply -f release/RestaurentService/smartdelivery-virtualservice.yaml
```
