# CI/CD Technical Specification

## Purpose
This document defines the standardized CI/CD model for SmartDeliveryInfra using reusable GitHub Actions workflows.

Goals:
- Minimize duplication across service pipelines.
- Keep workflows readable and easy to extend.
- Support both manual and branch/build-triggered deployments.

## Scope
Covers build and release workflows for these services:
- Auth Service
- Cart Service
- Order Service
- Payment Service
- Restaurant Service

## High-Level Architecture

### Build Layer
- Shared reusable workflow:
  - `.github/workflows/build-service-reusable.yml`
- Service wrappers (trigger + service config only):
  - `.github/workflows/build-authservice.yml`
  - `.github/workflows/build-cartservice.yml`
  - `.github/workflows/build-orderservice.yml`
  - `.github/workflows/build-paymentservice.yml`
  - `.github/workflows/build-restaurentservice.yml`

### Release Layer
- Shared reusable workflow:
  - `.github/workflows/release-service-reusable.yml`
- Service wrappers (trigger + manifest mapping only):
  - `.github/workflows/release-authservice.yml`
  - `.github/workflows/release-cartservice.yml`
  - `.github/workflows/release-orderservice.yml`
  - `.github/workflows/release-paymentservice.yml`
  - `.github/workflows/release-restaurentservice.yml`

## Build Workflow Specification

### Reusable Build Inputs
`build-service-reusable.yml` accepts:
- `service_display_name`
- `source_repo` (default: `PrakashRajanSakthivel/SmartDelivery`)
- `source_ref`
- `project_path`
- `service_folder`
- `dll_name`
- `dockerfile_name`
- `image_tag`
- `remove_default_appsettings` (optional, default `false`)

### Reusable Build Secrets
- `CODE_REPO_TOKEN`
- `GHCR_PAT`

### Build Execution Flow
1. Checkout source repository/ref.
2. Clean workspace.
3. Build and publish .NET service.
4. Generate runtime Dockerfile.
5. Login to GHCR.
6. Build and push image.

## Release Workflow Specification

### Reusable Release Inputs
`release-service-reusable.yml` accepts:
- Service identity: `service_display_name`, `image_name`, `deployment_name`, `app_label`
- Manifest mapping: `deployment_manifest`, `configmap_manifest`, `service_manifest`, `hpa_manifest`, `namespace_manifest`
- Optional Istio mapping: `enable_virtualservice`, `virtualservice_manifest`
- ConfigMap substitution mode: `configmap_mode` (`none`, `cart`, `order`, `restaurant`)
- Runtime context: `environment`, `build_run_id`, `trigger_source`
- Workflow-run propagation: `workflow_run_id`, `workflow_run_number`, `workflow_run_created_at`, `workflow_run_head_sha`, `workflow_run_head_branch`

### Reusable Release Secrets
Required:
- `KUBECONFIG`
- `HCLOUD_TOKEN`
- `FIREWALL_ID`
- `GHCR_PAT`

Optional (service-specific):
- `CART_DB_CONNECTION_STRING`
- `ORDER_DB_CONNECTION_STRING`
- `RESTAURANT_DB_CONNECTION_STRING`
- `JWT_SECRET_KEY`
- `JWT_ISSUER`
- `JWT_AUDIENCE`
- `ELASTICSEARCH_URI`

### Release Execution Flow
1. Resolve build metadata and image tag (`v<run_number>`, custom build id, or `latest`).
2. Configure kubectl using secret kubeconfig.
3. Open firewall port 6443 (Hetzner).
4. Apply namespace and pull secret.
5. Patch deployment image tag in mapped deployment manifest.
6. Process ConfigMap template based on `configmap_mode`.
7. Apply ConfigMap, Service, Deployment, HPA, and optional VirtualService.
8. Wait for rollout and verify resources.
9. Always close firewall port and publish summary.

## Trigger Model
Each service wrapper keeps trigger ownership:
- `workflow_dispatch` (manual run)
- `workflow_run` (on completion of matching build workflow)
- `push` and `pull_request` (branch + path filters)

This keeps service-level control readable while centralizing implementation.

## Design Principles
- Wrappers are declarative and short.
- Reusable workflows contain execution logic only.
- Service-specific behavior is driven by explicit inputs.
- Changes to pipeline behavior should be made once in reusable workflows.

## Onboarding a New Service
1. Add service manifests under `release/<ServiceName>/`.
2. Add one build wrapper pointing to `build-service-reusable.yml`.
3. Add one release wrapper pointing to `release-service-reusable.yml`.
4. Map image, deployment/app label, and manifest paths.
5. Set `configmap_mode` and optional secrets as needed.
6. Validate by running manual build and manual release once.

## Operational Notes
- Reusable release workflow edits manifest files in-run (`sed`) before applying.
- Restaurant service uses:
  - Image namespace `ghcr.io/prakashrajansakthivel/smartdeliveryinfra/restaurentservice`
  - Optional Istio VirtualService deployment.
- Build wrappers preserve service-specific source refs where required (e.g., Auth uses `feature/migration`).

## Future Enhancements
- Add OIDC-based registry auth to reduce PAT usage.
- Introduce environment promotion gates (staging -> production).
- Add policy checks for manifest schema and security scanning.
