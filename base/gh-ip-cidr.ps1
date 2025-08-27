# Fetch current GitHub Actions runner CIDRs and format for firewall rules

# Fetch the IP metadata
$meta = Invoke-RestMethod -Uri "https://api.github.com/meta"

# Extract the Actions runner CIDRs
$actionsCIDRs = $meta.actions

Write-Host "GitHub Actions runner CIDRs:"
$actionsCIDRs | ForEach-Object { Write-Host $_ }

$commaList = $actionsCIDRs -join ","
Write-Host "CSV for firewall allow-list:"
Write-Host $commaList

$fwPort = 6443
Write-Host "`nSample UFW commands:"
$actionsCIDRs | ForEach-Object { Write-Host "ufw allow from $_ to any port $fwPort" }

$actionsCIDRs | Out-File -Encoding ascii -FilePath ".\github-actions-cidrs.txt"
Write-Host "CIDRs saved to github-actions-cidrs.txt"