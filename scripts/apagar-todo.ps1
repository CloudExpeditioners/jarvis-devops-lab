<#
.SYNOPSIS
  FinOps: destruye NeoBanco al terminar los ensayos (lo caro es el App Service y los Private Endpoints).
  La plataforma (Service Bus, Function, Log Analytics) cuesta poco y puede quedarse encendida.

  Antes de destruir apaga a JARVIS (JARVIS_ENABLED=false): si no, el Centinela vería tu destroy
  como un cambio no autorizado y despertaría al agente.

  Recrear NeoBanco:
    gh variable set JARVIS_ENABLED --body true --repo <owner>/<repo>
    gh workflow run apply.yml --repo <owner>/<repo>      # unos 15 minutos
#>
param(
  [Parameter(Mandatory)] [string] $Repo,
  [switch] $TambienPlataforma
)
$ErrorActionPreference = "Stop"
gh variable set JARVIS_ENABLED --body false --repo $Repo
Write-Host "JARVIS apagado (interruptor). Destruyendo NeoBanco..." -ForegroundColor Yellow

Push-Location "$PSScriptRoot\..\infra\neobanco"
if (-not (Test-Path backend.hcl)) {
  # backend.hcl se genera desde la salida del bootstrap (no se sube a Git)
  $b = Get-Content "$PSScriptRoot\..\bootstrap\salida-bootstrap.json" | ConvertFrom-Json
  @"
resource_group_name  = "$($b.TFSTATE_RG)"
storage_account_name = "$($b.TFSTATE_SA)"
container_name       = "tfstate"
key                  = "neobanco.tfstate"
use_azuread_auth     = true
"@ | Set-Content backend.hcl -Encoding ascii
}
# Las comillas son obligatorias en PowerShell: el punto de backend.hcl parte el argumento
terraform init '-backend-config=backend.hcl' -input=false | Out-Null
terraform destroy -auto-approve
Pop-Location

if ($TambienPlataforma) {
  Push-Location "$PSScriptRoot\..\infra\plataforma"
  terraform destroy -auto-approve
  Pop-Location
}
Write-Host "Listo." -ForegroundColor Green
