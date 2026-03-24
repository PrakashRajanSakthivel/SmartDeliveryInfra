# patch-prometheus.ps1
# Applies alert rules and wires Alertmanager into the Prometheus ConfigMap.
# Run from repo root: .\release\monitoring\patch-prometheus.ps1
#
# Uses Python for all JSON/YAML manipulation to avoid Windows line-ending issues.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rulesFile = Join-Path $PSScriptRoot "alerting_rules.yml"

$pythonScript = @'
import sys, json, subprocess

rules_file = sys.argv[1]

# ── 1. Patch alerting_rules.yml ──────────────────────────────────────────────
with open(rules_file, 'r', encoding='utf-8') as f:
    rules = f.read().replace('\r\n', '\n').replace('\r', '\n')

patch = json.dumps({'data': {'alerting_rules.yml': rules}})
r = subprocess.run(
    ['kubectl', 'patch', 'configmap', 'prometheus', '-n', 'istio-system',
     '--type', 'merge', '--patch', patch],
    capture_output=True, text=True
)
print('alerting_rules.yml:', r.stdout.strip() or r.stderr.strip())

# ── 2. Patch alertmanager endpoint into prometheus.yml ───────────────────────
r2 = subprocess.run(
    ['kubectl', 'get', 'configmap', 'prometheus', '-n', 'istio-system', '-o', 'json'],
    capture_output=True, text=True
)
cm = json.loads(r2.stdout)
yml = cm['data']['prometheus.yml']
# Fix rule_files paths — Istio addon mounts at /etc/prometheus/, not /etc/config/
if '/etc/config/' in ymlo:
    ymlo = ymlo.replace('/etc/config/', '/etc/prometheus/')
    fix_patch = json.dumps({'data': {'prometheus.yml': ymlo}})
    subprocess.run(
        ['kubectl', 'patch', 'configmap', 'prometheus', '-n', 'istio-system',
         '--type', 'merge', '--patch', fix_patch],
        capture_output=True, text=True
    )
    print('rule_files paths: fixed /etc/config/ -> /etc/prometheus/')
if 'alertmanagers:' in yml:
    print('prometheus.yml: alertmanager endpoint already present, skipping.')
else:
    alerting_block = (
        '\nalerting:\n'
        '  alertmanagers:\n'
        '  - static_configs:\n'
        '    - targets:\n'
        '      - alertmanager.istio-system.svc:9093\n'
    )
    updated = yml.rstrip('\n') + alerting_block
    patch2 = json.dumps({'data': {'prometheus.yml': updated}})
    r3 = subprocess.run(
        ['kubectl', 'patch', 'configmap', 'prometheus', '-n', 'istio-system',
         '--type', 'merge', '--patch', patch2],
        capture_output=True, text=True
    )
    print('prometheus.yml:', r3.stdout.strip() or r3.stderr.strip())
'@

Write-Host "==> Patching Prometheus ConfigMap (rules + alertmanager endpoint)..."
python3 -c $pythonScript $rulesFile
Write-Host "    done."

Write-Host ""
Write-Host "==> Restarting Prometheus to pick up changes..."
kubectl rollout restart deployment/prometheus -n istio-system
kubectl rollout status deployment/prometheus -n istio-system --timeout=90s

Write-Host ""
Write-Host "All done. Verify alerts at:"
Write-Host "  kubectl port-forward svc/prometheus 9090:9090 -n istio-system"
Write-Host "  http://localhost:9090/alerts"
