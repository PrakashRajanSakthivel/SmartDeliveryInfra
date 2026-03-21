# Prometheus alert rules — SmartDelivery
#
# This is a strategic merge patch for the existing prometheus ConfigMap
# in istio-system. It fills in the alerting_rules.yml key which exists
# but is empty by default.
#
# Apply (single command, no cluster restart needed):
#   kubectl patch configmap prometheus -n istio-system --type merge \
#     --patch "$(kubectl create configmap tmp --from-file=alerting_rules.yml=release/monitoring/alerting_rules.yml --dry-run=client -o jsonpath='{.data}' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(json.dumps({'data':d}))\")"
#
# Simpler — build the patch inline with PowerShell:
#   $rules = Get-Content release/monitoring/alerting_rules.yml -Raw
#   $patch = @{ data = @{ "alerting_rules.yml" = $rules } } | ConvertTo-Json -Depth 5
#   kubectl patch configmap prometheus -n istio-system --type merge --patch $patch
#
# After patching, Prometheus picks up the rules within ~60s (no restart needed).
# Verify: kubectl port-forward svc/prometheus 9090:9090 -n istio-system
#         → open http://localhost:9090/alerts
