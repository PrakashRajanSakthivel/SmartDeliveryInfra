# Close Hetzner Firewall Port Script
# Usage: .\close-firewall-port.ps1 -Port 6443

param(
    [Parameter(Mandatory=$true)]
    [string]$Port,
    
    [Parameter(Mandatory=$false)]
    [string]$SourceIPs = "0.0.0.0/0"
)

# Get environment variables
$hcloudToken = $env:HCLOUD_TOKEN
$firewallId = $env:FIREWALL_ID

if (-not $hcloudToken) {
    Write-Error "HCLOUD_TOKEN environment variable is required"
    exit 1
}

if (-not $firewallId) {
    Write-Error "FIREWALL_ID environment variable is required"
    exit 1
}

# Setup headers
$headers = @{ 
    Authorization = "Bearer $hcloudToken"
    "Content-Type" = "application/json"
}

try {
    # Fetch the current firewall config
    Write-Host "Fetching current firewall configuration..."
    $fw = Invoke-RestMethod -Method Get -Uri "https://api.hetzner.cloud/v1/firewalls/$firewallId" -Headers $headers
    $existingRules = $fw.firewall.rules

    # Remove any rule matching the specified port and source IPs
    $updatedRules = @($existingRules) | Where-Object {
        !(($_.direction -eq "in") -and ($_.protocol -eq "tcp") -and ($_.port -eq $Port) -and ($_.source_ips -contains $SourceIPs))
    }

    # Check if any rules were removed
    if ($updatedRules.Count -eq $existingRules.Count) {
        Write-Host "No matching rule found for port $Port from $SourceIPs"
        exit 0
    }

    # Prepare update body
    $updateBody = @{
        rules = $updatedRules
    }

    $jsonBody = $updateBody | ConvertTo-Json -Depth 6
    
    Write-Host "Closing port $Port to $SourceIPs..."
    Invoke-RestMethod -Method Put -Uri "https://api.hetzner.cloud/v1/firewalls/$firewallId" -Headers $headers -Body $jsonBody
    
    Write-Host "Successfully closed port $Port to $SourceIPs"
    
} catch {
    Write-Error "Failed to close firewall port: $($_.Exception.Message)"
    Write-Error "Response: $($_.Exception.Response)"
    exit 1
}
