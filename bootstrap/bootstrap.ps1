<#
.SYNOPSIS
  Bootstrap de JARVIS en modo DevOps. Se ejecuta UNA sola vez, como Owner de la suscripción.

  Crea:
    - Registro de resource providers (el pipeline no tiene permisos para registrarlos)
    - Storage para el estado de Terraform (contenedor tfstate) y los reportes de drift (contenedor drift)
    - Dos identidades administradas con federación OIDC hacia GitHub (sin secretos):
        id-jarvis-plan  -> solo lectura (detectar drift, planes de PR)
        id-jarvis-apply -> escritura acotada a los RG de NeoBanco (apply y reconcile)
    - Permisos de datos sobre el tfstate para ambas identidades y para ti

.EXAMPLE
  .\bootstrap.ps1 -SubscriptionId "xxxx-xxxx" -GitHubOwner "tu-usuario" -GitHubRepo "jarvis-devops"
#>
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $GitHubOwner,
  [Parameter(Mandatory)] [string] $GitHubRepo,
  [string] $Location = "spaincentral",
  [string] $Prefix   = "jarvis",
  # Algunas cuentas/organizaciones de GitHub emiten el subject OIDC con IDs numéricos
  # (repo:owner@<id>/repo@<id>:environment:...). Si el login falla con AADSTS700213,
  # el error muestra el subject real: vuelve a ejecutar con -SubjectConIds.
  # Requiere que el repositorio ya exista y 'gh auth login' hecho.
  [switch] $SubjectConIds
)
$ErrorActionPreference = "Stop"

Write-Host "==> Seleccionando suscripción" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null
$tenantId  = az account show --query tenantId -o tsv
$miUsuario = az ad signed-in-user show --query id -o tsv

Write-Host "==> Registrando resource providers (puede tardar unos minutos)" -ForegroundColor Cyan
$providers = @("Microsoft.Web","Microsoft.Sql","Microsoft.KeyVault","Microsoft.Storage","Microsoft.Network",
               "Microsoft.OperationalInsights","Microsoft.Insights","Microsoft.ServiceBus","Microsoft.EventGrid",
               "Microsoft.ManagedIdentity","Microsoft.Consumption","Microsoft.PolicyInsights","Microsoft.Authorization",
               "Microsoft.PowerPlatform")  # necesario para el plan de pago por uso de Copilot Studio
foreach ($p in $providers) { az provider register --namespace $p --wait | Out-Null; Write-Host "   $p OK" }

$rgState = "rg-$Prefix-bootstrap"
$sufijo  = -join ((97..122) + (48..57) | Get-Random -Count 5 | ForEach-Object { [char]$_ })
$saName  = "st$($Prefix)tf$sufijo"

Write-Host "==> Creando $rgState y $saName" -ForegroundColor Cyan
az group create -n $rgState -l $Location --tags proyecto=jarvis-devops | Out-Null
az storage account create -n $saName -g $rgState -l $Location --sku Standard_ZRS --kind StorageV2 `
  --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false `
  --tags proyecto=jarvis-devops | Out-Null
az storage account blob-service-properties update --account-name $saName -g $rgState `
  --enable-versioning true --enable-delete-retention true --delete-retention-days 14 | Out-Null
$saId = az storage account show -n $saName -g $rgState --query id -o tsv

# Tu usuario necesita acceso de datos para crear contenedores y para ejecutar terraform en local
az role assignment create --assignee-object-id $miUsuario --assignee-principal-type User `
  --role "Storage Blob Data Contributor" --scope $saId | Out-Null
Write-Host "   Esperando propagación de RBAC (90 s)..."; Start-Sleep -Seconds 90
az storage container create --account-name $saName -n tfstate --auth-mode login | Out-Null
az storage container create --account-name $saName -n drift   --auth-mode login | Out-Null

Write-Host "==> Identidades administradas con federación OIDC" -ForegroundColor Cyan
$repo = "$GitHubOwner/$GitHubRepo"
if ($SubjectConIds) {
  $ownerId = gh api "repos/$repo" --jq ".owner.id"
  $repoId  = gh api "repos/$repo" --jq ".id"
  if (-not $ownerId -or -not $repoId) { throw "No pude leer los IDs de $repo. ¿Existe el repositorio y hiciste gh auth login?" }
  $subjectBase = "repo:$GitHubOwner@${ownerId}/$GitHubRepo@${repoId}"
} else {
  $subjectBase = "repo:$repo"
}
Write-Host "   Subject OIDC base: $subjectBase"
$ids = [ordered]@{
  "id-$Prefix-plan"  = @("neobanco-plan")
  "id-$Prefix-apply" = @("neobanco-prod","jarvis-auto")
}
$salida = @{}
foreach ($id in $ids.Keys) {
  az identity create -n $id -g $rgState -l $Location | Out-Null
  $clientId    = az identity show -n $id -g $rgState --query clientId -o tsv
  $principalId = az identity show -n $id -g $rgState --query principalId -o tsv
  foreach ($envName in $ids[$id]) {
    az identity federated-credential create --name "gh-$envName" --identity-name $id -g $rgState `
      --issuer "https://token.actions.githubusercontent.com" `
      --subject "${subjectBase}:environment:$envName" --audiences "api://AzureADTokenExchange" | Out-Null
    Write-Host "   $id <- environment $envName"
  }
  $salida[$id] = @{ clientId = $clientId; principalId = $principalId }
}

# Estado: ambas identidades usan el contenedor tfstate; plan además publica reportes en 'drift'
foreach ($id in $salida.Keys) {
  az role assignment create --assignee-object-id $salida[$id].principalId --assignee-principal-type ServicePrincipal `
    --role "Storage Blob Data Contributor" --scope "$saId/blobServices/default/containers/tfstate" | Out-Null
}
az role assignment create --assignee-object-id $salida["id-$Prefix-plan"].principalId --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" --scope "$saId/blobServices/default/containers/drift" | Out-Null

$resumen = [ordered]@{
  AZURE_TENANT_ID       = $tenantId
  AZURE_SUBSCRIPTION_ID = $SubscriptionId
  AZURE_CLIENT_ID_PLAN  = $salida["id-$Prefix-plan"].clientId
  AZURE_CLIENT_ID_APPLY = $salida["id-$Prefix-apply"].clientId
  PLAN_PRINCIPAL_ID     = $salida["id-$Prefix-plan"].principalId
  APPLY_PRINCIPAL_ID    = $salida["id-$Prefix-apply"].principalId
  TFSTATE_RG            = $rgState
  TFSTATE_SA            = $saName
  TFSTATE_SA_ID         = $saId
  MI_USUARIO_OBJECT_ID  = $miUsuario
  UBICACION             = $Location
}
$resumen | ConvertTo-Json | Set-Content -Path "$PSScriptRoot\salida-bootstrap.json" -Encoding utf8
Write-Host "`n==> Listo. Valores guardados en bootstrap\salida-bootstrap.json (está en .gitignore):" -ForegroundColor Green
$resumen.GetEnumerator() | ForEach-Object { "{0,-24} {1}" -f $_.Key, $_.Value }
