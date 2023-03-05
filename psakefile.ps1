Properties {
    $script:rootDir = FindRootDir
    $script:verbose = $true
    $script:k8scluster = 'vaultk8s'
    $script:k8scontext = "k3d-$k8scluster"
    $script:registryPort = 5002
    $script:registry = "localhost:$registryPort"
    $script:k8sns = 'sample'
    $script:k8sDir = Join-Path $rootDir k8s
    $script:vaultDir = Join-Path $rootDir .vault
    $script:kubeConfigHome = Join-Path ($env:HOME, $env:USERPROFILE -ne $null)[0] '.kube'
    $script:sleep = 5
    $script:helmBaseName = 'sample1'
}

FormatTaskName (("-" * 25) + "[{0}]" + ("-" * 25))

# main deployment task
Task Build-K8sCluster -depends Build-K8sClusterInfrastructure, Deploy-Application

Task Build-K8sClusterInfrastructure -depends New-K8sCluster, Set-K8sConfigFile, `
    New-ApplicationNamespace, Set-K8sLocalContext, Install-InfrastructureServices

Task Install-InfrastructureServices -depends Connect-MongoToVault

Task Deploy-Application -depends Set-K8sLocalContext, Build-Images, Build-Tags, `
    Publish-Images, Deploy-ApplicationChart, Get-K8sIngressUrl, Request-K8sService

Task Update-Application -depends Set-K8sLocalContext, Build-Images, Build-Tags, `
    Publish-Images, Remove-ApplicationPods, Get-K8sIngressUrl, Request-K8sService

# main removal task
Task Remove-AllInfrastructure -depends Remove-K3dCluster, Remove-K8sConfig, Remove-VaultDir

Task Remove-InfrastructureServices -depends Remove-Vault, Remove-Mongo

# main reset task
Task Reset-AllInfrastructure -depends Remove-AllInfrastructure, Build-K8sCluster

Task Reset-K8sCluster -depends Remove-Vault, Reset-ApplicationNamespace, Install-InfrastructureServices, Deploy-Application

Task Reset-ApplicationNamespace -depends Remove-ApplicationNamespace, New-ApplicationNamespace

Task Test-vault {
    if (!(Get-Command vault -ErrorAction Ignore)) {
        throw "vault not found. Install from https://developer.hashicorp.com/vault/docs/install"
    }
}

Task Test-kubectl {
    if (!(Get-Command kubectl -ErrorAction Ignore)) {
        throw "kubectl not found. Install with: https://kubernetes.io/docs/tasks/tools/"
    }
}

Task Test-helm -depends Test-kubectl {
    if (!(Get-Command helm -ErrorAction Ignore)) {
        throw "helm  not found. Install with https://helm.sh/"
    }
}

Task Test-docker {
    if (!(Get-Command docker -ErrorAction Ignore)) {
        throw "docker not found. Get it at https://docker.com/ or get Rancher at https://rancher.com/"
    }
}

Task Test-k3d {
    if (!(Get-Command k3d -ErrorAction Ignore)) {
        throw "k3d not found. Get it at https://k3d.io/"
    }
}

Task Install-CliTools {
    if ($IsWindows) {
        $tools = @()
        if (!(Get-Command kubectl -ErrorAction Ignore)) { $tools += 'kubectl' }
        if (!(Get-Command helm -ErrorAction Ignore)) { $tools += 'helm' }
        if (!(Get-Command docker -ErrorAction Ignore)) { $tools += 'docker' }
        if (!(Get-Command k3d -ErrorAction Ignore)) { $tools += 'k3d' }
        if (!(Get-Command vault -ErrorAction Ignore)) { $tools += 'vault' }
        if ($tools.Count -eq 0) {
            Write-Host "All tools already installed."
            return
        } else {
            scoop install $tools
        }
    } else {
        Write-Host "Install tools manually."
    }
}

Task New-K8sCluster -depends Test-k3d {
    if (!(Resolve-DnsName k8s.localhost -QuickTimeout -ErrorAction SilentlyContinue)) {
        Write-Error "You need to add k8s.localhost to your hosts file."
    }
    if (k3d cluster ls -ojson | ConvertFrom-Json | Where-Object { $_.name -eq $k8scluster } ) {
        Write-Host "Cluster already exists."
    } else {
        Exec { k3d cluster create $k8scluster --agents 2 --servers 1 -p '80:80@loadbalancer' --wait --timeout 120s --kubeconfig-update-default=false --registry-create registry:0.0.0.0:$registryPort }
    }
    Exec { k3d kubeconfig write $k8scluster --overwrite --output $kubeConfigHome/$k8scluster }
    Exec { k3d cluster ls }
}

Task Remove-K3dCluster -depends Test-k3d {
    if (k3d cluster ls -ojson | ConvertFrom-Json | Where-Object { $_.name -eq $k8scluster } ) {
        Exec { k3d cluster delete $k8scluster }
    } else {
        Write-Host "Cluster does not exist."
    }
    if (Test-Path $kubeConfigHome/$k8scluster) {
        Remove-Item $kubeConfigHome/$k8scluster
    }
    Exec { k3d cluster ls }
}

Task Set-K8sConfigFile -depends Test-kubectl, Test-k3d {
    $configAlreadyWritten = $false
    kubectl config get-contexts $k8scontext --no-headers 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $configAlreadyWritten = $true
        Write-Host "Config already written to file."
        return
    }
    if (!($configAlreadyWritten)) {
        $configFile = Join-Path $kubeConfigHome $k8scluster
        Write-Host Writing config to $configFile
        Exec { k3d kubeconfig write $k8scluster --overwrite --output $kubeConfigHome/$k8scluster }
    }
    $kubeConfigAltered = $false
    if ($env:KUBECONFIG) {
        if (!($env:KUBECONFIG.Contains($configFile))) {
            $kubeConfigAltered = $true
            $env:KUBECONFIG += "$([System.IO.Path]::PathSeparator)$configFile"
        }
    } else {
        $kubeConfigAltered = $true
        $env:KUBECONFIG = "$kubeConfigHome$([System.IO.Path]::DirectorySeparatorChar)config$([System.IO.Path]::PathSeparator)$configFile"
    }
    if ($kubeConfigAltered) {
        Write-Host "`$KUBECONFIG env var now is '$env:KUBECONFIG'"
    }
    if (!($IsWindows)) {
        Write-Host "You have to manually set your `$KUBECONFIG environment variable if you are calling from Bash. Run:`nexport KUBECONFIG=$env:KUBECONFIG"
    }
}

Task Remove-K8sConfig -depends Test-kubectl {
    try {
        kubectl config get-contexts $k8scontext --no-headers 2>$null | Out-Null
    } catch {
        Write-Host "Config not set."
        return
    }
    $configFile = Join-Path $kubeConfigHome $k8scluster
    if (Test-Path $configFile) { Remove-Item $configFile }
    if ($env:KUBECONFIG) {
        $env:KUBECONFIG = $env:KUBECONFIG.Replace("$([System.IO.Path]::PathSeparator)$configFile", "")
        Write-Host "`$KUBECONFIG unset"
    }
}

Task Set-K8sLocalContext -depends Test-kubectl, Set-K8sConfigFile {
    Exec { kubectl config use-context $k8scontext }
    Exec { kubectl config set-context $k8scontext --namespace=$k8sns }
}

Task Set-K8sLocalContextToDefaultNamespace -depends Test-kubectl, Set-K8sConfigFile {
    Exec { kubectl config use-context $k8scontext }
    Exec { kubectl config set-context $k8scontext --namespace=default }
}

Task Deploy-Mongo -depends Test-helm {
    Exec {
        if (helm list --filter 'mongo' --namespace $k8sns --no-headers) {
            Write-Host Mongo already installed.
        } else {
            Write-Host Installing Mongo...
            if (helm repo list -ojson | ConvertFrom-Json | Where-Object { $_.name -eq 'bitnami' }) {
                Exec { helm repo update bitnami }
            } else {
                Exec { helm repo add bitnami https://charts.bitnami.com/bitnami }
            }
            Exec {
                Write-Output @"
auth:
  rootPassword: Passw0rd
  databases:
   - appdb
  usernames:
   - webappuser
  passwords:
   - Passw0rd2
"@ | helm install mongo bitnami/mongodb --namespace $k8sns --create-namespace --atomic --wait --wait-for-jobs --version ^13.8.2 --timeout 120s --values -
                # helm install mongo bitnami/mongodb --namespace $k8sns --create-namespace --atomic --wait --wait-for-jobs --version ^13.8.2 --timeout 120s --set-string 'auth.rootPassword=Passw0rd,auth.databases={appdb},auth.usernames={webappuser},auth.passwords={Passw0rd2}'
            }
        }
    }
}

Task Deploy-Vault -depends Test-helm {
    if (!(Resolve-DnsName vault.localhost -QuickTimeout -ErrorAction SilentlyContinue)) {
        Write-Error "You need to add vault.localhost to your hosts file."
    }
    if (helm list --filter 'vault' --namespace $k8sns --no-headers) {
        Write-Host Vault already installed, checking if vault is unsealed.
        # todo: check if each vault pod is unsealed, this is only checking the first pod
        $env:VAULT_ADDR = 'http://vault.localhost'
        vault status | Out-Null
        if ($LASTEXITCODE -eq 2) {
            Write-Host Vault is sealed. Unsealing.
            Invoke-psake 'Unseal-Vault'
        } else {
            Write-Host Vault is unsealed.
        }
    } else {
        Write-Host Installing Vault...

        if (helm repo list -ojson | ConvertFrom-Json | Where-Object { $_.name -eq 'hashicorp' }) {
            Exec { helm repo update hashicorp }
        } else {
            Exec { helm repo add hashicorp https://helm.releases.hashicorp.com }
        }
        Exec { Write-Output @"
server:
  affinity: null
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
ui:
  enabled: true
  serviceType: ClusterIP
"@ | helm install vault hashicorp/vault --namespace $k8sns --atomic --create-namespace --wait --wait-for-jobs --version ~0.23.0 --timeout 180s --values - }
        Exec { Write-Output @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vault-ui
  annotations:
    ingress.kubernetes.io/ssl-redirect: "false"
spec:
  rules:
  - host: vault.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vault-ui
            port:
              number: 8200
"@ | kubectl apply -f - }
        $vaultPods = (Exec { kubectl get pods --namespace $k8sns -l "app.kubernetes.io/name=vault" -o jsonpath="{.items}" } | ConvertFrom-Json).metadata.name | Sort-Object
        Write-Host "Vault pods: $vaultPods"
        $vaultPodName0 = $vaultPods[0]
        if (!(Test-Path $vaultDir)) { New-Item -ItemType Directory -Path $vaultDir | Out-Null }
        $progressPreference = 'silentlyContinue'
        while ($(try { Invoke-WebRequest $env:VAULT_ADDR/v1/sys/health } catch { $_.Exception.Response }).StatusCode -ne 501) {
            Start-Sleep -Seconds $sleep
            Write-Host Waiting for vault to become available...
        }
        $progressPreference = 'Continue'
        $vaultInit = Exec { kubectl exec --namespace $k8sns -ti $vaultPodName0 -- vault operator init --format=json } | ConvertFrom-Json
        Write-Host Vault init: ($vaultInit | ConvertTo-Json)
        $keys = $vaultInit.unseal_keys_b64
        $keys | Out-File (Join-Path $vaultDir keys)
        $vaultPods | ForEach-Object {
            $vaultPodName = $_
            if ($vaultPodName0 -ne $vaultPodName) {
                Write-Host "Joining vault pod $vaultPodName to raft..."
                Exec { kubectl exec --namespace $k8sns -ti $vaultPodName -- vault operator raft join http://$vaultPodName0.vault-internal:8200 }
            }
            Write-Host "Unsealing vault pod $vaultPodName..."
            $keys | Select-Object -First 3 | ForEach-Object { Exec { kubectl exec --namespace $k8sns -ti $vaultPodName -- vault operator unseal $_ } }
        }
        $rootToken = $vaultInit.root_token
        $rootToken | Out-File (Join-Path $vaultDir token)
        WaitForVaultReady
        Invoke-Task 'Login-Vault'
        $env:VAULT_ADDR = 'http://vault.localhost'
        Exec { vault status }
        Exec { vault audit enable file file_path=stdout }
        Exec { vault token create -id=mytoken }
        Exec { vault login mytoken }
        Exec { vault secrets enable database }
        $authList = vault auth list --format json | ConvertFrom-Json
        if (!($authList.PSObject.Properties.Value | Where-Object { $_.type -eq 'kubernetes' })) {
            Exec { vault auth enable kubernetes }
            if ($LASTEXITCODE -ne 0) { throw "Could not enable auth kubernetes." }
        }
        $k8sHost = kubectl exec --namespace $k8sns -ti $vaultPodName0 -- sh -c 'echo https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'
        Exec { vault write auth/kubernetes/config kubernetes_host=$k8sHost }
        Exec { vault write sys/internal/counters/config enabled=enable retention_months=1 }
        Exec { vault auth enable userpass }
        Exec {
            Write-Output @"
# All in sys
path "sys/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
# Enable and manage authentication methods broadly across Vault
path "auth/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
# List, create, update, and delete key/value secrets
path "secret/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
# Manage dbs
path "database/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
"@ | vault policy write admins -
        }
        Exec { vault write auth/userpass/users/admin password=pwd policies=admins }
    }
}

Task Unseal-Vault -depends Test-helm {
    $keys = Get-Content (Join-Path $vaultDir keys)
    $vaultPods = (Exec { kubectl get pods --namespace $k8sns -l "app.kubernetes.io/name=vault" -o jsonpath="{.items}" } | ConvertFrom-Json).metadata.name | Sort-Object
    $c = '' # todo: change when https://github.com/PowerShell/PSScriptAnalyzer/issues/1163 is fixed, change to use -Begin in ForEach-Object
    $cmd = $keys | Select-Object -First 3 | ForEach-Object -Process { $c += "vault operator unseal $_; " } -End { $c }
    $vaultPods | ForEach-Object { $pod = $_; kubectl exec --namespace $k8sns -ti $pod -- sh -c "vault status > /dev/null; if [ `$? -eq '2' ]; then $cmd else echo 'Pod $pod is already unsealed.'; fi"; if ($LASTEXITCODE -ne 0) { throw "Could not unseal vault pod $pod." } }
}

Task Login-Vault -depends Test-helm {
    $env:VAULT_ADDR = 'http://vault.localhost'
    $rootToken = Get-Content (Join-Path $vaultDir token)
    Exec { vault login $rootToken }
}

Task Connect-MongoToVault -depends Deploy-Vault, Deploy-Mongo {
    while ([System.Convert]::ToInt32((kubectl get deployment --namespace $k8sns mongo-mongodb -o jsonpath='{.status.availableReplicas}')) -lt 1) {
        Start-Sleep -Seconds $sleep
        Write-Host Waiting for mongo...
    }
    $env:VAULT_ADDR = 'http://vault.localhost'
    if (vault list database/config | Where-Object { $_ -eq 'samplemongo' }) {
        Write-Host "Vault connection to mongo already configured."
        return
    }
    $mongoPod = ''
    $theMongoPod = [ref]$mongoPod
    Exec -maxRetries 3 {
        $mongoPod = kubectl get pods --namespace $k8sns -l "app.kubernetes.io/name=mongodb" -o jsonpath="{.items[0].metadata.name}"
        if ($LASTEXITCODE -ne 0) { throw "Could not get mongo pod." }
        if (!($mongoPod)) { throw "mongoPod is null." }
        kubectl exec --namespace $k8sns -ti $mongoPod -- mongosh appdb -u webappuser -p Passw0rd2 --eval 'if (db.products.countDocuments() == 0) db.products.insertMany([{ name: "apple" }, { name: "lemon" }]); db.products.find();'
        if ($LASTEXITCODE -ne 0) { throw "Could not insert products." }
        $theMongoPod.value = $mongoPod
    }
    Exec -maxRetries 3 { vault write database/config/samplemongo `
            plugin_name=mongodb-database-plugin `
            allowed_roles='webapp-role' `
            connection_url="mongodb://{{username}}:{{password}}@mongo-mongodb.$k8sns.svc.cluster.local/admin" `
            username='root' `
            password='Passw0rd'
    }
    Exec -maxRetries 3 { vault write database/roles/webapp-role `
            db_name=samplemongo `
            creation_statements='{ "db": "appdb", "roles": [{ "role": "readWrite" }] }' `
            revocation_statements='{ "db": "appdb" }' `
            default_ttl='60s' `
            max_ttl='120s'
    }
    Exec -maxRetries 3 {
        Write-Output @"
path "database/creds/webapp-role" {
  capabilities = ["read"]
}

path "sys/leases/renew" {
  capabilities = ["create"]
}

path "sys/leases/revoke" {
  capabilities = ["update"]
}
"@ | vault policy write mongo-policy -
    }
    Exec -maxRetries 3 { vault write auth/kubernetes/role/mongo `
            bound_service_account_names=vault `
            bound_service_account_namespaces=$k8sns `
            policies=mongo-policy `
            ttl=24h
    }
}

Task Disconnect-MongoToVault -depends Test-kubectl, Test-vault {
    if ([System.Convert]::ToInt32((kubectl get deployment mongo-mongodb -o jsonpath='{.status.availableReplicas}')) -gt 0) {
        Exec -maxRetries 3 {
            $mongoPod = kubectl get pods --namespace $k8sns -l "app.kubernetes.io/name=mongodb" -o jsonpath="{.items[0].metadata.name}"
            if ($LASTEXITCODE -ne 0) { throw "Could not get mongo pod." }
            if (!($mongoPod)) { throw "mongoPod is null." }
            # kubectl exec -ti $mongoPod -- mongosh admin -u root -p Passw0rd --eval 'db.getSiblingDB("appdb").dropDatabase();'
            kubectl exec -ti --namespace $k8sns $mongoPod -- mongosh appdb --quiet -u webappuser -p Passw0rd2 --eval 'if (db.products.countDocuments() != 0) db.products.drop();'
            if ($LASTEXITCODE -ne 0) { throw "Could not delete products." }
        }
    }
    $vaultPodName = kubectl get pods --namespace $k8sns -l "app.kubernetes.io/name=vault" -o jsonpath="{.items[0].metadata.name}"
    if ($vaultPodName) {
        $env:VAULT_ADDR = 'http://vault.localhost'
        Exec { vault delete database/config/samplemongo }
        Exec { vault delete database/roles/webapp-role }
        Exec { vault policy delete mongo-policy }
    }
}

Task Remove-Vault -depends Test-vault, Test-helm, Remove-VaultDir {
    if (helm list --filter 'vault' --namespace $k8sns --no-headers) {
        Write-Host Deleting Vault...
        Exec { helm delete vault --namespace $k8sns --wait --timeout 1m }
        Exec { kubectl delete pvc --namespace $k8sns -l "app.kubernetes.io/name=vault" }
        Exec { kubectl delete ingress --namespace $k8sns vault-ui }
    } else {
        Write-Host Vault not installed.
    }
}

Task Remove-VaultDir {
    if (Test-Path $vaultDir) { Remove-Item -Recurse -Force $vaultDir }
}

Task Remove-Mongo -depends Test-helm {
    Exec {
        if (helm list --filter 'mongo' --namespace $k8sns --no-headers) {
            Write-Host Deleting Mongo...
            Exec { helm delete mongo --namespace $k8sns --wait --timeout 1m }
            Exec { kubectl delete pvc --namespace $k8sns -l "app.kubernetes.io/name=mongo" }
        } else {
            Write-Host Mongo not installed.
        }
    }
}

Task Build-Images -depends Test-docker {
    Get-ChildItem Dockerfile -Path $rootDir -Depth 2 | ForEach-Object { Exec { docker build --tag "$($_.Directory.Name.ToLower()):latest" -f $_.FullName "$rootDir" } }
}

Task Build-Tags -depends Test-docker {
    Get-ChildItem Dockerfile -Path $rootDir -Depth 2 | ForEach-Object { docker tag "$($_.Directory.Name.ToLower()):latest" "$registry/$($_.Directory.Name.ToLower()):latest" }
}

Task Delete-Images -depends Test-docker {
    $noneImages = docker image list --filter reference=$registry/* --format '{{.Repository}}:{{.Tag}}%{{.ID}}' `
    | Where-Object { $_.Contains(':<none>%') } `
    | ForEach-Object { $_.Split('%')[1] }
    foreach ($image in $noneImages) {
        docker image rm $image
    }
    $images = docker image list --filter reference=$registry/* --format '{{.Repository}}:{{.Tag}}'
    foreach ($image in $images) {
        docker image rm $image
    }
    Get-ChildItem Dockerfile -Path $rootDir -Depth 2 | ForEach-Object {
        $images = docker image list --filter "reference=$($_.Directory.Name.ToLower()):*" --format '{{.Repository}}:{{.Tag}}'
        foreach ($image in $images) {
            docker image rm $image
        }
    }
}

Task Publish-Images -depends Test-docker {
    $images = docker image list --filter reference=$registry/* --format '{{.Repository}}:latest' | Get-Unique
    foreach ($image in $images) {
        docker push $image
    }
}

Task New-ApplicationNamespace -depends Test-kubectl {
    if (!(kubectl get namespace $k8sns --ignore-not-found=true)) {
        Write-Host "Creating k8s namespace $k8sns..."
        Exec { kubectl create namespace $k8sns }
    }
}

Task Deploy-ApplicationChart -depends Set-K8sLocalContext, New-ApplicationNamespace {
    $upgrade = $false
    if (helm list --filter $helmBaseName --namespace $k8sns --no-headers) {
        $upgrade = $true
    }
    Exec { helm upgrade --namespace $k8sns --install $helmBaseName $rootDir/src/VaultApi/chart/ --atomic --timeout 1m }
    if ($upgrade) {
        Invoke-Task 'Remove-ApplicationPods'
    }
}

Task Remove-Application -depends Test-Helm {
    if (helm list --filter $helmBaseName --namespace $k8sns --no-headers) {
        Write-Host Deleting Vault...
        Exec { helm delete $helmBaseName --namespace $k8sns --wait --timeout 1m }
    } else {
        Write-Host Application not installed.
    }
}

Task Remove-ApplicationNamespace -depends Test-kubectl, Set-K8sLocalContext {
    if (kubectl get namespace $k8sns --ignore-not-found=true | Out-Null) {
        Exec { kubectl delete namespace $k8sns --wait=true }
    }
}

Task Remove-ApplicationPods -depends Test-kubectl {
    Exec { kubectl delete pod --namespace $k8sns -l "app.kubernetes.io/name=vaultapi" }
}

Task Get-K8sIngressUrl -depends Test-kubectl {
    $url = "http://$(GetK8sIngressUrl)"
    Write-Host "Service available at $url"
}

Task Request-K8sService -depends Test-kubectl {
    $isPodReady = ''
    $times = 0
    while ($isPodReady -ne 'true') {
        if ($times -gt 5) { throw 'Timeout waiting for pod to get ready' }
        Start-Sleep 2
        $times++
        $isPodReady = Exec { kubectl get pods --namespace $k8sns -l "app.kubernetes.io/name=vaultapi" -o jsonpath="{.items[0].status.containerStatuses[0].ready}" }
    }
    $url = "http://$(GetK8sIngressUrl)/"
    Write-Host "Requesting $url..."
    curl -fSs $url
    Write-Host
    $url = "http://$(GetK8sIngressUrl)/products"
    Write-Host "Requesting $url..."
    if ((Get-Command bat -ErrorAction SilentlyContinue) -and (Get-Command jq -ErrorAction SilentlyContinue)) {
        Exec { curl -fSs $url | jq | bat --language json --paging never --file-name $url }
    } else {
        Exec { curl -fSs $url }
    }
}

Task Connect-ToVault -depends Set-K8sLocalContext {
    $env:VAULT_ADDR = 'http://127.0.0.1:8200'
    if (helm list --filter 'vault' --namespace $k8sns --no-headers) {
        $vaultPodName0 = Exec { kubectl get pods --namespace $k8sns -l "app.kubernetes.io/name=vault" -o jsonpath="{.items[0].metadata.name}" }
        Start-Process -FilePath kubectl -ArgumentList "port-forward $vaultPodName0 8200".Split(' ') -PassThru
        Write-Host Remember to set environment variable: `$env:VAULT_ADDR = 'http://127.0.0.1:8200'
    } else {
        Write-Host Vault not installed.
    }
}

Task Get-MongoPassword {
    $env:VAULT_ADDR = 'http://vault.localhost'
    vault read database/creds/webapp-role
}

Task Drop-VaultLeases {
    $env:VAULT_ADDR = 'http://vault.localhost'
    vault lease revoke -prefix database
}

Task Rotate-MongoPassword {
    $env:VAULT_ADDR = 'http://vault.localhost'
    Exec { vault write -force database/rotate-root/samplemongo } # not yet implemented, will fail
}

# tasks for development without k8s
Task Start-LocalMongo {
    $containerName = 'mongo'
    if (docker ps -aqf name=$containerName) {
        if (!(docker ps -qf name=$containerName)) {
            Exec { docker start $containerName }
        }
    } else {
        Exec { docker run --name $containerName -p 27017:27017 -d $containerName }
        $times = 0
        while ($true) {
            if ($times -gt $sleep) { throw "Mongo container was not started on time." }
            docker exec -ti $containerName mongosh appdb --quiet --eval 'console.log("ready");' | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep 1
            $times++
        }
        Exec { docker exec -ti $containerName mongosh appdb --quiet --eval 'if (db.products.countDocuments() == 0) db.products.insertMany([{ name: "apple" }, { name: "lemon" }]); db.products.find();' }
    }
}

Task Stop-LocalMongo {
    $containerName = 'mongo'
    if (docker ps -qf name=$containerName) {
        Exec { docker stop $containerName }
    }
}

Task Remove-LocalMongo {
    $containerName = 'mongo'
    if (docker ps -aqf name=$containerName) {
        Exec { docker rm -f $containerName }
    }
}

Task Echo { Write-Host echo }

function GetK8sIngressUrl() {
    Exec { kubectl get ingress --namespace $k8sns $helmBaseName-vaultapi -o jsonpath="{.spec.rules[0].host}" }
}

function FindRootDir() {
    $dir = ""
    if ($env:SYSTEM_DEFAULTWORKINGDIRECTORY) {
        $dir = $env:SYSTEM_DEFAULTWORKINGDIRECTORY
    } else {
        $dir = Split-Path $psake.build_script_file
    }
    return $dir
}

function WaitForVaultReady {
    $arePodsReady = ''
    $times = 0
    while ($arePodsReady -ne 'true') {
        if ($times -gt 5) { throw 'Timeout waiting for pod to get ready' }
        Start-Sleep 2
        $times++
        $statuses = Exec { k get statefulsets.apps vault --namespace $k8sns -o jsonpath="{.status}" | ConvertFrom-Json }
        $arePodsReady = $statuses.readyReplicas -eq $statuses.replicas
    }
}

function RunConnectedToVault {
    Param (
        [parameter(Position = 0, Mandatory = 1)]
        [ScriptBlock]$cmd
    )
    $env:VAULT_ADDR = 'http://127.0.0.1:8200'
    $vaultAlreadyConnected = $false
    try {
        $testConnection = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 8200)
        $vaultAlreadyConnected = $true
        $testConnection.Dispose()
    } catch {
    }
    if ($vaultAlreadyConnected) {
        Write-Host "Vault is already connected."
        & $cmd
        return
    }
    $vaultPodName0 = ((Exec { kubectl get pods --namespace $k8sns -l "app.kubernetes.io/name=vault" -o jsonpath="{.items}" } | ConvertFrom-Json).metadata.name | Sort-Object)[0]
    $retrycount = 0
    while ($true) {
        $portForwardProcess = Start-Process -FilePath kubectl -ArgumentList "port-forward --namespace $k8sns $vaultPodName0 8200".Split(' ') -PassThru
        Start-Sleep -Seconds 3
        if ($portForwardProcess.HasExited) {
            if ($retrycount -ge 10) {
                Write-Host Vault port forwarding process has exited.
            }
        } else {
            vault status | Out-Null
            # 0 - unsealed, 1 - error, 2 - sealed
            if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 2) {
                break
            } else {
                KillProcessHierarchy $portForwardProcess.Id
                Write-Host Por forwarding succeeded, but Vault is not ready.
            }
        }
        $retrycount++
        if ($retrycount -ge 10) {
            throw "Vault port forwarding failed."
        } else {
            Write-Host Port forwarding failed, retrying...
        }
    }
    Write-Host "Vault is connected."
    try {
        & $cmd
    } finally {
        KillProcessHierarchy $portForwardProcess.Id
    }
}

function KillProcessHierarchy($processId) {
    if (!($IsLinux)) {
        Start-Process -FilePath taskkill.exe -ArgumentList "/PID $processId /T /F".Split(' ') -Wait
    } else {
        Start-Process -FilePath pkill -ArgumentList "-9 -s $processId".Split(' ') -Wait
    }
}
