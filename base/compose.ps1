<#
.SYNOPSIS
    Builds a service-account kubeconfig for CI and optionally stores it as the KUBECONFIG secret.

.DESCRIPTION
    The CA must come from the working kubeconfig (kubectl config view --minify --raw), which is
    the k3s server CA. Do NOT source it from a service-account secret in istio-system - that is
    Istio's CA and produces "x509: certificate signed by unknown authority" at connect time.

    Verifies the composed kubeconfig can actually reach the cluster before handing it onward, so
    a broken credential never reaches the secret.

.PARAMETER SetSecret
    Pipe the result straight into `gh secret set KUBECONFIG` instead of writing it to disk. The
    credential never lands in the working tree, which matters - this repo is public.

.PARAMETER Duration
    Token lifetime. The previous default was kubectl's 1 hour, which silently produced a secret
    that expired before it was ever used.

.EXAMPLE
    .\compose.ps1 -SetSecret
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ServiceAccount = "gha-deployer",

    [Parameter(Mandatory=$false)]
    [string]$Namespace = "kube-system",

    [Parameter(Mandatory=$false)]
    [string]$ClusterName = "default",

    [Parameter(Mandatory=$false)]
    [string]$Duration = "8760h",

    [Parameter(Mandatory=$false)]
    [switch]$SetSecret
)

$ErrorActionPreference = "Stop"

# Prefer kubectl on PATH; fall back to the copy kept in the repo root.
$kubectl = (Get-Command kubectl -ErrorAction SilentlyContinue).Source
if (-not $kubectl) {
    $local = Join-Path $PSScriptRoot "..\kubectl.exe"
    if (Test-Path $local) { $kubectl = (Resolve-Path $local).Path }
    else { Write-Error "kubectl not found on PATH or at repo root"; exit 1 }
}

$ApiServer = & $kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
$CAData    = & $kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'

if (-not $ApiServer) { Write-Error "Could not read the API server URL from the current context"; exit 1 }
if (-not $CAData)    { Write-Error "Could not read certificate-authority-data (is --raw supported?)"; exit 1 }
Write-Host "API server: $ApiServer"

$Token = & $kubectl create token $ServiceAccount -n $Namespace --duration=$Duration
if (-not $Token) { Write-Error "Failed to mint a token for $ServiceAccount"; exit 1 }

# The API server may clamp the requested lifetime (--service-account-max-token-expiration),
# so report what was actually granted rather than what was asked for.
try {
    $payload = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($payload.Length % 4) { $payload += '=' }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $expiry = [DateTimeOffset]::FromUnixTimeSeconds($claims.exp).UtcDateTime
    Write-Host "Token expires: $($expiry.ToString('yyyy-MM-dd HH:mm')) UTC  (requested $Duration)"
} catch {
    Write-Host "Token minted (could not decode expiry claim)"
}

$Kubeconfig = @"
apiVersion: v1
kind: Config
clusters:
- name: $ClusterName
  cluster:
    server: $ApiServer
    certificate-authority-data: $CAData
users:
- name: $ServiceAccount
  user:
    token: $Token
contexts:
- name: gha-context
  context:
    cluster: $ClusterName
    user: $ServiceAccount
current-context: gha-context
"@

# Verify before handing it on: a kubeconfig that cannot list namespaces would fail the release
# pipeline's validate step anyway, and debugging that from CI logs is far slower than here.
$probe = New-TemporaryFile
try {
    $Kubeconfig | Out-File -Encoding ascii -FilePath $probe.FullName
    & $kubectl --kubeconfig=$($probe.FullName) get namespace smartdelivery | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Composed kubeconfig could not reach the cluster; not storing it."; exit 1 }
    Write-Host "Verified: the composed kubeconfig can reach the cluster."
} finally {
    Remove-Item $probe.FullName -Force -ErrorAction SilentlyContinue
}

if ($SetSecret) {
    $Kubeconfig | gh secret set KUBECONFIG
    if ($LASTEXITCODE -ne 0) { Write-Error "gh secret set failed"; exit 1 }
    Write-Host "Stored as the KUBECONFIG repo secret."
} else {
    $Kubeconfig | Out-File -Encoding ascii -FilePath ".\gha-kubeconfig.yaml"
    Write-Host "Saved to gha-kubeconfig.yaml (gitignored). Delete it once the secret is set."
}
