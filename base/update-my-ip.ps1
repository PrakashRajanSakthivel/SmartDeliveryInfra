<#
.SYNOPSIS
    Points Hetzner firewall admin-access rules at this machine's current public IP.

.DESCRIPTION
    Home broadband hands out a dynamic IP, so the rules allowing SSH (2222) and the k3s API
    (6443) go stale without warning. The symptom is those ports timing out while 443 still
    answers, because 443 is open to the world.

    Unlike open-firewall-port.ps1, this REPLACES the source IP on the rules it owns rather than
    appending another rule, so repeated runs cannot accumulate stale entries. Ownership is
    tracked by the rule description below; every other rule passes through untouched - including
    the transient 0.0.0.0/0 port-6443 rule that CI opens and closes around a deploy.

    Handles multiple firewalls: pass several ids, or set FIREWALL_ID to a comma-separated list.
    Idempotent - if the rules already name the current IP, no write is made.

.PARAMETER List
    Show every firewall on the account with its inbound rules and the servers it protects, then
    exit. Use this to work out which firewall ids to pass. Needs only a read token.

.PARAMETER FirewallIds
    Firewall ids to update. Falls back to $env:FIREWALL_ID (comma- or space-separated).

.PARAMETER Ports
    TCP ports to keep open to this machine. Defaults to SSH and the k3s API.

.PARAMETER DryRun
    Report what would change without calling the API.

.EXAMPLE
    $env:HCLOUD_TOKEN = "<read-write token>"
    .\update-my-ip.ps1 -List

.EXAMPLE
    .\update-my-ip.ps1 -FirewallIds 1234567, 7654321
#>

param(
    [Parameter(Mandatory=$false)]
    [string[]]$FirewallIds,

    [Parameter(Mandatory=$false)]
    [int[]]$Ports = @(2222, 6443),

    [Parameter(Mandatory=$false)]
    [switch]$List,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Marker identifying rules this script owns. Changing it orphans the existing rules.
$ManagedPrefix = "admin-access (managed by update-my-ip.ps1)"

$hcloudToken = $env:HCLOUD_TOKEN
if (-not $hcloudToken) { Write-Error "HCLOUD_TOKEN environment variable is required"; exit 1 }

$headers = @{
    Authorization  = "Bearer $hcloudToken"
    "Content-Type" = "application/json"
}

# --- Discovery mode ------------------------------------------------------------------------
if ($List) {
    $all = (Invoke-RestMethod -Method Get -Uri "https://api.hetzner.cloud/v1/firewalls" -Headers $headers).firewalls
    if (-not $all) { Write-Host "No firewalls found on this account."; exit 0 }

    foreach ($fw in $all) {
        $servers = @($fw.applied_to | Where-Object { $_.type -eq "server" } | ForEach-Object { $_.server.id })
        Write-Host ""
        Write-Host "id=$($fw.id)  name=$($fw.name)"
        Write-Host "  applied to server(s): $(if ($servers) { $servers -join ', ' } else { '(none)' })"
        foreach ($r in @($fw.rules | Where-Object { $_.direction -eq "in" })) {
            $owned = if ($r.description -like "$ManagedPrefix*") { "  <- managed by this script" } else { "" }
            Write-Host ("    in  {0,-5} port {1,-6} from {2}{3}" -f $r.protocol, $r.port, ($r.source_ips -join ","), $owned)
        }
    }
    Write-Host ""
    Write-Host "Pass the relevant ids: .\update-my-ip.ps1 -FirewallIds <id1>, <id2>"
    exit 0
}

# --- Resolve target firewalls --------------------------------------------------------------
if (-not $FirewallIds -and $env:FIREWALL_ID) {
    $FirewallIds = $env:FIREWALL_ID -split '[,;\s]+' | Where-Object { $_ }
}
if (-not $FirewallIds) {
    Write-Error "No firewall ids. Pass -FirewallIds, set FIREWALL_ID, or run -List to discover them."
    exit 1
}

# --- Detect current public IP (several sources; any one may be blocked or rate-limited) -----
$myIp = $null
foreach ($svc in @("https://api.ipify.org", "https://checkip.amazonaws.com", "https://ifconfig.me/ip")) {
    try {
        $candidate = (Invoke-RestMethod -Method Get -Uri $svc -TimeoutSec 10).ToString().Trim()
        if ($candidate -match '^\d{1,3}(\.\d{1,3}){3}$') { $myIp = $candidate; break }
    } catch {
        Write-Host "  (couldn't reach $svc, trying next)"
    }
}
if (-not $myIp) { Write-Error "Could not determine public IP from any source"; exit 1 }

$myCidr = "$myIp/32"
Write-Host "Current public IP: $myIp"

function Update-Firewall {
    param([string]$Id)

    $fw = (Invoke-RestMethod -Method Get -Uri "https://api.hetzner.cloud/v1/firewalls/$Id" -Headers $headers).firewall
    $existing = @($fw.rules)
    Write-Host ""
    Write-Host "Firewall '$($fw.name)' (id=$Id) - $($existing.Count) rule(s)"

    $preserved = @($existing | Where-Object { $_.description -notlike "$ManagedPrefix*" })
    $ownedNow  = @($existing | Where-Object { $_.description -like  "$ManagedPrefix*" })

    # Already correct? Then skip the write entirely.
    $correct = ($ownedNow.Count -eq $Ports.Count)
    if ($correct) {
        foreach ($port in $Ports) {
            $rule = $ownedNow | Where-Object { $_.port -eq "$port" }
            if (-not $rule -or @($rule.source_ips).Count -ne 1 -or $rule.source_ips[0] -ne $myCidr) {
                $correct = $false; break
            }
        }
    }
    if ($correct) { Write-Host "  already points at $myCidr - nothing to do."; return }

    foreach ($r in $ownedNow) {
        Write-Host ("  replacing port {0}: {1} -> {2}" -f $r.port, ($r.source_ips -join ", "), $myCidr)
    }
    if (-not $ownedNow) { Write-Host "  adding rules for port(s) $($Ports -join ', ') from $myCidr" }

    # Rebuild preserved rules as plain hashtables so ConvertTo-Json emits only fields the API
    # accepts - a rule echoed back from a GET carries nulls that set_rules rejects.
    $rules = @()
    foreach ($r in $preserved) {
        $entry = @{ direction = $r.direction; protocol = $r.protocol; description = $r.description }
        if ($null -ne $r.port)     { $entry.port = $r.port }
        if ($r.direction -eq "in") { $entry.source_ips = @($r.source_ips) }
        else                       { $entry.destination_ips = @($r.destination_ips) }
        $rules += $entry
    }
    foreach ($port in $Ports) {
        $rules += @{
            direction   = "in"
            protocol    = "tcp"
            port        = "$port"
            source_ips  = @($myCidr)
            description = $ManagedPrefix
        }
    }

    if ($DryRun) {
        Write-Host "  [dry run] would submit $($rules.Count) rule(s), no change made:"
        foreach ($e in $rules) {
            $ips = if ($e.source_ips) { $e.source_ips -join "," } else { $e.destination_ips -join "," }
            Write-Host ("    {0,-3} {1,-5} port {2,-6} {3}" -f $e.direction, $e.protocol, $e.port, $ips)
        }
        return
    }

    $body = @{ rules = $rules } | ConvertTo-Json -Depth 6
    $action = Invoke-RestMethod -Method Post -Headers $headers -Body $body `
        -Uri "https://api.hetzner.cloud/v1/firewalls/$Id/actions/set_rules"

    $actionId = $action.actions[0].id
    $waited = 0
    do {
        Start-Sleep -Seconds 2
        $waited += 2
        $status = (Invoke-RestMethod -Method Get -Headers $headers `
            -Uri "https://api.hetzner.cloud/v1/firewalls/$Id/actions/$actionId").action.status
        if ($status -eq "success") { break }
        if ($status -eq "error")   { throw "Hetzner rejected the rule update for firewall $Id" }
    } while ($waited -lt 30)

    if ($status -ne "success") { Write-Warning "  timed out waiting for confirmation; verify in the console." }
    else { Write-Host "  ports $($Ports -join ', ') now open to $myCidr" }
}

$failed = 0
foreach ($id in $FirewallIds) {
    try { Update-Firewall -Id $id }
    catch { Write-Warning "Firewall $id failed: $($_.Exception.Message)"; $failed++ }
}
if ($failed) { exit 1 }
