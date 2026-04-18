# Port-forward all observability components for local access.
# Each service opens in a background job so they all run simultaneously.
#
# URLs after running this script:
#   Grafana    → http://localhost:3000   (admin / prom-operator)
#   Kiali      → http://localhost:20001
#   Jaeger     → http://localhost:16686
#   Prometheus → http://localhost:9090
#   Kibana     → http://localhost:5601
#
# Usage:
#   .\base\port-forward-observability.ps1
#
# To stop all forwards:
#   Get-Job | Stop-Job | Remove-Job

$forwards = @(
    @{ Namespace = "istio-system"; Service = "grafana";    Local = 3000;  Remote = 3000  },
    @{ Namespace = "istio-system"; Service = "kiali";      Local = 20001; Remote = 20001 },
    @{ Namespace = "istio-system"; Service = "tracing";    Local = 16686; Remote = 16686 },
    @{ Namespace = "istio-system"; Service = "prometheus"; Local = 9090;  Remote = 9090  },
    @{ Namespace = "logging";      Service = "kibana";     Local = 5601;  Remote = 5601  }
)

foreach ($fwd in $forwards) {
    $jobName = "pf-$($fwd.Service)"
    # Stop any existing job with the same name
    Get-Job -Name $jobName -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job

    $cmd = "kubectl port-forward svc/$($fwd.Service) $($fwd.Local):$($fwd.Remote) -n $($fwd.Namespace)"
    Start-Job -Name $jobName -ScriptBlock {
        param($c) Invoke-Expression $c
    } -ArgumentList $cmd | Out-Null

    Write-Host "Started: $($fwd.Service) → http://localhost:$($fwd.Local)"
}

Write-Host ""
Write-Host "All port-forwards running as background jobs."
Write-Host "Stop all: Get-Job | Stop-Job | Remove-Job"
