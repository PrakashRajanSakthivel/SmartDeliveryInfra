# chaos-runner.ps1
# ============================================================================
# Phase 3 Chaos Testing — SmartDelivery
#
# Applies, monitors, and removes Istio fault injection experiments.
# Run from the repo root.  Requires kubectl in PATH and a valid kubeconfig.
#
# Usage:
#   .\release\chaos\chaos-runner.ps1 -Experiment delay   # payment-service 5s delay
#   .\release\chaos\chaos-runner.ps1 -Experiment abort   # order-service 503 abort
#   .\release\chaos\chaos-runner.ps1 -Experiment all     # both together
#   .\release\chaos\chaos-runner.ps1 -Cleanup            # remove all chaos VS
#   .\release\chaos\chaos-runner.ps1 -Experiment pod-kill # delete a random pod
# ============================================================================
param(
    [ValidateSet("delay", "abort", "all", "pod-kill")]
    [string]$Experiment,
    [switch]$Cleanup
)

$ns = "smartdelivery"
$chaosDir = Join-Path $PSScriptRoot ""

function Write-Header($msg) {
    Write-Host ""
    Write-Host "=== $msg ===" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Success($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Info($msg)    { Write-Host "[..] $msg" -ForegroundColor Yellow }
function Write-Err($msg)     { Write-Host "[!!] $msg" -ForegroundColor Red }

# ── CLEANUP ──────────────────────────────────────────────────────────────────
if ($Cleanup) {
    Write-Header "Removing all chaos VirtualServices"
    $chaosVS = kubectl get virtualservice -n $ns -l "chaos=true" -o name 2>&1
    if ($chaosVS -match "No resources") {
        Write-Info "No chaos VirtualServices found — cluster is clean"
    } else {
        kubectl delete virtualservice -n $ns -l "chaos=true"
        Write-Success "All chaos VirtualServices removed"
    }
    exit 0
}

# ── HELPERS ──────────────────────────────────────────────────────────────────
function Apply-Delay {
    Write-Header "Experiment: payment-service HTTP Delay (5s, 100%)"
    kubectl apply -f "$chaosDir\payment-service-delay.yaml"
    Write-Success "Fault injection active — payment-service responses will stall 5s"
    Write-Info "Observe: Jaeger → search 'payment-service' for long spans"
    Write-Info "Observe: Grafana → SmartDelivery dashboard → PaymentService p95 latency"
}

function Apply-Abort {
    Write-Header "Experiment: order-service HTTP Abort (503, 100%)"
    kubectl apply -f "$chaosDir\order-service-abort.yaml"
    Write-Success "Fault injection active — order-service returns 503 immediately"
    Write-Info "Observe: Grafana → SmartDelivery dashboard → OrderService error rate"
    Write-Info "Observe: Kiali → service graph → red badge on order-service"
    Write-Info "Observe: Jaeger → traces show status_code=503 for order-service spans"
}

function Run-PodKill {
    Write-Header "Experiment: random pod deletion in namespace $ns"
    $pods = kubectl get pods -n $ns -o jsonpath='{.items[*].metadata.name}' 2>&1
    $podList = $pods -split " " | Where-Object { $_ -ne "" }
    if ($podList.Count -eq 0) {
        Write-Err "No pods found in namespace $ns"
        exit 1
    }
    $target = $podList | Get-Random
    Write-Info "Deleting pod: $target"
    kubectl delete pod $target -n $ns
    Write-Info "Waiting 15s for Kubernetes to reschedule..."
    Start-Sleep -Seconds 15
    Write-Info "Current pod state:"
    kubectl get pods -n $ns -o wide
    Write-Success "Self-healing check done — verify all pods return to Running/2/2"
}

function Show-ActiveChaos {
    Write-Header "Active chaos VirtualServices"
    $result = kubectl get virtualservice -n $ns -l "chaos=true" 2>&1
    if ($result -match "No resources") {
        Write-Info "None — cluster is clean"
    } else {
        Write-Host $result
    }
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
if (-not $Experiment -and -not $Cleanup) {
    Write-Host @"
Usage:
  .\release\chaos\chaos-runner.ps1 -Experiment delay    # payment-service 5s delay
  .\release\chaos\chaos-runner.ps1 -Experiment abort    # order-service 503 abort
  .\release\chaos\chaos-runner.ps1 -Experiment all      # both simultaneously
  .\release\chaos\chaos-runner.ps1 -Experiment pod-kill # delete random pod
  .\release\chaos\chaos-runner.ps1 -Cleanup             # remove all chaos VSes
"@
    exit 0
}

Show-ActiveChaos

switch ($Experiment) {
    "delay"    { Apply-Delay }
    "abort"    { Apply-Abort }
    "all"      { Apply-Delay; Apply-Abort }
    "pod-kill" { Run-PodKill }
}

Write-Host ""
Write-Host "Remember to run -Cleanup when done to restore normal behaviour." -ForegroundColor Magenta
