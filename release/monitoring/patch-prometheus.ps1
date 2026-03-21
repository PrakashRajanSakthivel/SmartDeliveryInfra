# patch-prometheus.ps1
# Applies alert rules and wires Alertmanager into the Prometheus ConfigMap.
# Run from repo root: .\release\monitoring\patch-prometheus.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "==> Patching alerting_rules.yml into prometheus ConfigMap..."
$rules = Get-Content "$PSScriptRoot\alerting_rules.yml" -Raw
$escapedRules = $rules -replace '\\', '\\\\' -replace '"', '\"'
$rulesPatch = "{`"data`":{`"alerting_rules.yml`":`"$($escapedRules -replace "`n", '\n')`"}}"
kubectl patch configmap prometheus -n istio-system --type merge --patch $rulesPatch
Write-Host "    done."

Write-Host "==> Patching alertmanager endpoint into prometheus.yml..."
# Read current prometheus.yml
$currentYml = kubectl get configmap prometheus -n istio-system -o jsonpath='{.data.prometheus\.yml}'

# Only add alerting block if it's not already there
if ($currentYml -notmatch "alertmanagers:") {
    $alertingBlock = @"

alerting:
  alertmanagers:
  - static_configs:
    - targets:
      - alertmanager.istio-system.svc:9093
"@
    $updatedYml = $currentYml + $alertingBlock
    $escapedYml  = $updatedYml -replace '\\', '\\\\' -replace '"', '\"'
    $ymPatch = "{`"data`":{`"prometheus.yml`":`"$($escapedYml -replace "`n", '\n')`"}}"
    kubectl patch configmap prometheus -n istio-system --type merge --patch $ymPatch
    Write-Host "    done."
} else {
    Write-Host "    alertmanager endpoint already present, skipping."
}

Write-Host ""
Write-Host "==> Restarting Prometheus to pick up changes..."
kubectl rollout restart deployment/prometheus -n istio-system
kubectl rollout status deployment/prometheus -n istio-system --timeout=60s

Write-Host ""
Write-Host "All done. Verify alerts at:"
Write-Host "  kubectl port-forward svc/prometheus 9090:9090 -n istio-system"
Write-Host "  http://localhost:9090/alerts"
