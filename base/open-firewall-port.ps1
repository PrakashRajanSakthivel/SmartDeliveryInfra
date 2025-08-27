# Open Hetzner Firewall Port Script
# Usage: .\open-firewall-port.ps1 -Port 6443 -Description "Kubernetes API for CI/CD"

param(
    [Parameter(Mandatory=$true)]
    [string]$Port,
    
    [Parameter(Mandatory=$false)]
    [string]$Description = "Opened for CI/CD",
    
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

    # Check if rule already exists
    $ruleExists = $existingRules | Where-Object {
        ($_.direction -eq "in") -and ($_.protocol -eq "tcp") -and ($_.port -eq $Port) -and ($_.source_ips -contains $SourceIPs)
    }
    
    # Debug: Show what we're looking for
    Write-Host "Looking for rule: Direction=in, Protocol=tcp, Port=$Port, SourceIPs=$SourceIPs"
    Write-Host "Found $($ruleExists.Count) existing rules"

    if ($ruleExists) {
        Write-Host "Port $Port rule already exists for source $SourceIPs"
        exit 0
    }

    # Compose new rule
    $newRule = @{
        direction = "in"
        protocol = "tcp"
        port = $Port
        source_ips = @($SourceIPs)
        description = $Description
    }

    # Add new rule to existing rules
    $updatedRules = @($existingRules) + @($newRule)

    # Prepare update body
    $updateBody = @{
        rules = $updatedRules
    }

    $jsonBody = $updateBody | ConvertTo-Json -Depth 6
    
                Write-Host "Opening port $Port to $SourceIPs..."
            
            # Use Set Rules action instead of direct PUT
            $actionResponse = Invoke-RestMethod -Method Post -Uri "https://api.hetzner.cloud/v1/firewalls/$firewallId/actions/set_rules" -Headers $headers -Body $jsonBody
            Write-Host "✅ Set Rules action initiated! Action ID: $($actionResponse.action.id)"
            
            # Wait for action to complete
            $actionId = $actionResponse.action.id
            $maxWait = 30
            $waitCount = 0
            
            do {
                Start-Sleep -Seconds 2
                $waitCount += 2
                
                $actionStatus = Invoke-RestMethod -Method Get -Uri "https://api.hetzner.cloud/v1/firewalls/$firewallId/actions/$actionId" -Headers $headers
                
                if ($actionStatus.action.status -eq "success") {
                    Write-Host "✅ Action completed successfully!"
                    break
                } elseif ($actionStatus.action.status -eq "error") {
                    Write-Error "❌ Action failed: $($actionStatus.action.error.message)"
                    exit 1
                }
                
            } while ($waitCount -lt $maxWait)
            
            if ($waitCount -ge $maxWait) {
                Write-Error "⚠️  Action timed out after $maxWait seconds"
                exit 1
            }
            
            Write-Host "Successfully opened port $Port to $SourceIPs"
    
} catch {
    Write-Error "Failed to open firewall port: $($_.Exception.Message)"
    Write-Error "Response: $($_.Exception.Response)"
    exit 1
}
