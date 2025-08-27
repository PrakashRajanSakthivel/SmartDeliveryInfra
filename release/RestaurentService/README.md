# Restaurant Service Deployment

This directory contains Kubernetes manifests for deploying the Restaurant Service to k3s.

## Prerequisites

1. **k3s Cluster**: A running k3s cluster with kubectl access
2. **GitHub Secrets**: The following secrets must be configured in your GitHub repository:
   - `KUBECONFIG`: Base64 encoded kubeconfig file for your k3s cluster
   - `GHCR_PAT`: GitHub Container Registry Personal Access Token
   - `HCLOUD_TOKEN`: Hetzner Cloud API token (for firewall management)
   - `FIREWALL_ID`: Hetzner Cloud firewall ID

3. **Istio** (Optional): If you want to use the VirtualService for ingress routing

## Required Permissions

### GitHub Actions Permissions
The workflow requires the following permissions:

```yaml
permissions:
  contents: read
  packages: write  # For pushing to GHCR
  actions: read
```

### Kubernetes RBAC Permissions
The deployment uses the existing GitHub Actions ServiceAccount (`gha-deployer`) with enhanced permissions:

1. **ServiceAccount**: `gha-deployer` (in kube-system namespace)
2. **ClusterRole**: `gha-deployer-role` with permissions for:
   - Namespace operations (get, list, create, update, patch, delete)
   - Pod operations (get, list, watch, create, update, patch, delete)
   - Service operations (get, list, watch, create, update, patch, delete)
   - ConfigMap operations (get, list, watch, create, update, patch, delete)
   - Secret operations (get, list, watch, create, update, patch, delete)
   - Deployment operations (get, list, watch, create, update, patch, delete)
   - HPA operations (get, list, watch, create, update, patch, delete)
   - NetworkPolicy operations (get, list, watch, create, update, patch, delete)
   - Istio VirtualService operations (get, list, watch, create, update, patch, delete)
   - Event operations (get, list, watch, create, patch, update)

3. **ClusterRoleBinding**: `gha-deployer-binding`

### Network Security
The deployment uses default Kubernetes networking without additional NetworkPolicies for simplicity. Traffic is controlled through:
- **Service**: Internal cluster communication
- **Istio VirtualService**: External ingress routing (if Istio is available)

## Deployment Components

### Core Resources
1. **Namespace**: `smartdelivery` with proper labels
2. **ConfigMap**: `restaurent-service-config` with application settings
3. **Service**: `restaurent-service` exposing port 80
4. **Deployment**: `restaurent-service` with 2 replicas (no ServiceAccount)
5. **HPA**: `restaurent-service-hpa` for auto-scaling (1-5 replicas)

### Optional Resources
6. **VirtualService**: `smartdelivery-vs` (if Istio is available)

## Deployment Process

### Manual Deployment
1. Run the GitHub Actions workflow manually:
   ```bash
   # Trigger the workflow via GitHub UI or API
   gh workflow run release-restaurentservice.yml
   ```

### Automatic Deployment
The workflow triggers automatically on:
- Push to `main` branch with changes to `release/RestaurentService/**`
- Changes to the release workflow file

## Configuration

### Environment Variables
- `environment`: Choose between 'production' or 'staging' (default: production)

### Image Configuration
- **Image**: `ghcr.io/prakashrajansakthivel/restaurant:latest`
- **Pull Policy**: `Always` (ensures latest image is pulled)

### Resource Limits
- **CPU**: 250m request, 500m limit
- **Memory**: 256Mi request, 512Mi limit

## Monitoring and Verification

### Health Checks
The deployment includes:
- Pod readiness checks
- Service connectivity tests
- Deployment status verification

### Logs and Debugging
```bash
# Check pod status
kubectl get pods -n smartdelivery -l app=restaurent-service

# View logs
kubectl logs -n smartdelivery -l app=restaurent-service

# Check service status
kubectl get svc -n smartdelivery

# Check HPA status
kubectl get hpa -n smartdelivery
```

## Troubleshooting

### Common Issues

1. **Image Pull Errors**
   - Verify GHCR_PAT secret is correct
   - Check image exists in GHCR
   - Ensure image pull secret is created

2. **Permission Denied**
   - Verify gha-deployer ServiceAccount has proper permissions
   - Check ClusterRoleBinding exists in kube-system namespace
   - Ensure GitHub Actions token is valid

3. **Network Connectivity**
   - Check firewall rules for port 6443
   - Ensure Istio VirtualService is deployed (if using Istio)
   - Verify service endpoints are created

4. **Resource Constraints**
   - Check cluster has sufficient CPU/Memory
   - Verify HPA configuration
   - Monitor resource usage

### Rollback
To rollback to a previous deployment:
```bash
kubectl rollout undo deployment/restaurent-service -n smartdelivery
```

## Security Considerations

1. **Image Security**: Images are pulled from GHCR with authentication
2. **Network Security**: Uses default Kubernetes networking (can add NetworkPolicies later if needed)
3. **RBAC**: GitHub Actions ServiceAccount has least privilege permissions
4. **Secrets**: Database credentials stored in ConfigMap (consider using Secrets for production)
5. **Firewall**: Kubernetes API access is temporary and controlled

## Next Steps

1. **Database Setup**: Configure and deploy the database service
2. **Monitoring**: Add Prometheus/Grafana for metrics
3. **Logging**: Configure centralized logging (ELK stack)
4. **SSL/TLS**: Configure HTTPS with proper certificates
5. **Backup**: Implement database backup strategies
