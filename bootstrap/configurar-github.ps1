<#
.SYNOPSIS
  Configura variables, secretos, environments y labels del repo con la CLI 'gh'.
  Requisitos: gh auth login, bootstrap.ps1 ejecutado, infra/plataforma aplicada y la GitHub App creada.

.EXAMPLE
  .\configurar-github.ps1 -GitHubOwner "tu-usuario" -GitHubRepo "jarvis-devops" `
     -GitHubAppId 123456 -RutaClavePrivadaApp "C:\claves\jarvis-neobanco.pem"
#>
param(
  [Parameter(Mandatory)] [string] $GitHubOwner,
  [Parameter(Mandatory)] [string] $GitHubRepo,
  [Parameter(Mandatory)] [string] $GitHubAppId,
  [Parameter(Mandatory)] [string] $RutaClavePrivadaApp,
  [int] $MaxTargets = 5
)
$ErrorActionPreference = "Stop"
$repo = "$GitHubOwner/$GitHubRepo"
$b = Get-Content "$PSScriptRoot\salida-bootstrap.json" | ConvertFrom-Json

Push-Location "$PSScriptRoot\..\infra\plataforma"
$sbFqdn = terraform output -raw servicebus_fqdn
Pop-Location

$vars = [ordered]@{
  AZURE_TENANT_ID       = $b.AZURE_TENANT_ID
  AZURE_SUBSCRIPTION_ID = $b.AZURE_SUBSCRIPTION_ID
  AZURE_CLIENT_ID_PLAN  = $b.AZURE_CLIENT_ID_PLAN
  AZURE_CLIENT_ID_APPLY = $b.AZURE_CLIENT_ID_APPLY
  TFSTATE_RG            = $b.TFSTATE_RG
  TFSTATE_SA            = $b.TFSTATE_SA
  SB_FQDN               = $sbFqdn
  JARVIS_ENABLED        = "true"   # interruptor de apagado
  MAX_TARGETS           = "$MaxTargets"
  JARVIS_APP_ID         = $GitHubAppId
}
foreach ($k in $vars.Keys) { gh variable set $k --repo $repo --body $vars[$k] | Out-Null; Write-Host "var    $k" }
Get-Content $RutaClavePrivadaApp -Raw | gh secret set JARVIS_APP_PRIVATE_KEY --repo $repo
Write-Host "secret JARVIS_APP_PRIVATE_KEY"

foreach ($envName in @("neobanco-plan","neobanco-prod","jarvis-auto")) {
  gh api -X PUT "repos/$repo/environments/$envName" --silent
  Write-Host "env    $envName"
}
# jarvis-auto y neobanco-prod solo pueden desplegar desde main
foreach ($envName in @("neobanco-prod","jarvis-auto")) {
  gh api -X PUT "repos/$repo/environments/$envName" `
    -F "deployment_branch_policy[protected_branches]=false" `
    -F "deployment_branch_policy[custom_branch_policies]=true" --silent
  gh api -X POST "repos/$repo/environments/$envName/deployment-branch-policies" -f name=main -f type=branch --silent
}

gh label create jarvis    --repo $repo --color 3FD0FF --description "Propuesto por JARVIS" --force
gh label create incidente --repo $repo --color F5B841 --description "Ticket de incidente generado por JARVIS" --force
Write-Host "`nListo. Opcional: protege la rama main (Settings > Branches). Ver docs/RUNBOOK-IMPLEMENTACION.md." -ForegroundColor Green
