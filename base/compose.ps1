# Parameters - change these as needed
$ServiceAccount = "gha-deployer"
$Namespace = "kube-system"
$ClusterName = "default"

# Get cluster info
$ApiServer = kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
$CAData = kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'

#$CAData = kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'

# For k8s v1.25+ (projected tokens)
$Token = kubectl create token $ServiceAccount -n $Namespace

# Compose kubeconfig
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

# Output to file
$Kubeconfig | Out-File -Encoding ascii -FilePath ".\gha-kubeconfig.yaml"

Write-Host "Minimal kubeconfig saved to gha-kubeconfig.yaml"