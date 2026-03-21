# SmartDelivery — Infrastructure

Kubernetes infrastructure for the [SmartDelivery](SmartDelivery/) microservices showcase. Runs on a single-node k3s cluster on Hetzner VPS with Istio service mesh, full observability stack, and GitHub Actions CI/CD.

## Architecture

```
Cloudflare → Istio IngressGateway → 5 .NET microservices (Istio sidecar mesh)
                                          ↓
                              Prometheus · Grafana · Jaeger · Kiali
                                          ↓
                              Elasticsearch · Kibana (logging namespace)
```

**Cluster:** k3s v1.33.3 · single node · 4 vCPU / 7.5 GiB · Hetzner CX22
**Istio:** 1.25.2 · individual Helm charts · resources tuned for single-node
**Observability:** Istio-bundled Prometheus + Grafana + Jaeger + Kiali · kube-state-metrics · node-exporter

## Repository Layout

| Path | Purpose |
|---|---|
| `release/` | kubectl-apply manifests — namespaces, deployments, HPAs, configmaps |
| `Smart/` | Helm values files for all components (reflects live cluster state) |
| `base/` | GHA kubeconfig template + firewall scripts |
| `docs/` | Architecture, infra spec, CI/CD spec, repo-vs-cluster audit |

## Before You Deploy

Two placeholders must be filled in before applying manifests:

**1. JWT Secret Key** — used by all 5 services to sign authentication tokens.
Replace `__JWT_SECRET_KEY__` in each `release/<Service>/*-configmap.yaml` with a strong random string (minimum 32 characters):

```bash
# Generate one:
openssl rand -base64 32
```

**2. Image pull secret** — required to pull images from GHCR.
Edit `release/image-pull-secret.yaml` with your registry credentials, then apply it locally (never commit the real values):

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat> \
  -n smartdelivery --dry-run=client -o yaml > release/image-pull-secret.yaml
```

## Deploy (new cluster)

See the full ordered runbook in [docs/REPO_VS_CLUSTER_AUDIT.md](docs/REPO_VS_CLUSTER_AUDIT.md#migration-runbook-new-provider).

Quick summary:
```bash
# 1. Istio
helm install istio-base istio/base -n istio-system --create-namespace -f Smart/istio-base-values.yaml
helm install istiod istio/istiod -n istio-system -f Smart/istiod-values.yaml
helm install istio-ingressgateway istio/gateway -n istio-system -f Smart/gateway-values.yaml

# 2. Observability addons
kubectl apply -f Smart/istio-addons.yaml

# 3. Services
kubectl apply -f release/namespace.yaml
kubectl apply -f release/image-pull-secret.yaml   # fill in real creds first
kubectl apply -f release/AuthService/
kubectl apply -f release/CartService/
kubectl apply -f release/OrderService/
kubectl apply -f release/PaymentService/
kubectl apply -f release/RestaurentService/

# 4. Logging
kubectl apply -f release/logging/namespace.yaml
kubectl apply -f release/logging/elasticsearch-pv.yaml   # hostPath on Hetzner Volume
kubectl apply -f release/logging/elasticsearch-pvc.yaml
kubectl apply -f release/logging/elasticsearch.yaml
kubectl apply -f release/logging/kibana.yaml

# 5. Cluster observability (Helm)
helm install kube-state-metrics prometheus-community/kube-state-metrics -n kube-system -f Smart/kube-state-metrics-values.yaml
helm install node-exporter prometheus-community/prometheus-node-exporter -n kube-system -f Smart/node-exporter-values.yaml
helm install headlamp headlamp/headlamp -n kube-system -f Smart/headlamp-values.yaml
```

## CI/CD

GitHub Actions workflows in `base/gha.yaml`. Triggered on push to `main`.
Requires GHA secrets: `KUBECONFIG` (base64-encoded kubeconfig), `GHCR_TOKEN`.

To regenerate the deploy token:
```bash
kubectl create token gha-deployer -n kube-system --duration=8760h
```

## Documentation

| Document | Purpose |
|---|---|
| [docs/INFRA_SPEC.md](docs/INFRA_SPEC.md) | Node resources, namespace layout, component versions |
| [docs/OBSERVABILITY_ARCH.md](docs/OBSERVABILITY_ARCH.md) | Metric collection flow, Prometheus scrape topology, Grafana dashboards |
| [docs/REPO_VS_CLUSTER_AUDIT.md](docs/REPO_VS_CLUSTER_AUDIT.md) | Live cluster vs repo diff, migration runbook |
| [docs/TECH_SPEC_CICD.md](docs/TECH_SPEC_CICD.md) | CI/CD pipeline specification |
| [SmartDelivery/TECH_SPEC.md](SmartDelivery/TECH_SPEC.md) | Application architecture |