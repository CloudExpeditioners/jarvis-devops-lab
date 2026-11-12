<#
.SYNOPSIS
  Limpieza tras un ensayo, sin depender de JARVIS.
  - Ejecuta el workflow apply (reconcilia todo con main, p. ej. devuelve el SKU a lo que dice Git)
  - Opcional: -QuitarRolStorage borra la asignación de rol del escenario 'rolstorage'.
    Borrar permisos exige MFA reciente y GENERA UN EVENTO: apaga a JARVIS antes
    (gh variable set JARVIS_ENABLED --body false) y enciéndelo después de ~3 minutos.
#>
param([Parameter(Mandatory)] [string] $Repo, [string] $RgCore = "rg-neobanco-core", [switch] $QuitarRolStorage)
$ErrorActionPreference = "Stop"
if ($QuitarRolStorage) {
  $yo = az ad signed-in-user show --query id -o tsv
  $st = az storage account list -g $RgCore --query "[?tags.rol=='transacciones'].id | [0]" -o tsv
  az role assignment delete --assignee $yo --role "Storage Blob Data Reader" --scope $st
  if ($LASTEXITCODE -ne 0) { throw "No se pudo borrar el rol. Si pidió MFA: az login --tenant <tenant> con el claims-challenge que muestra el error." }
}
gh workflow run apply.yml --repo $Repo
Write-Host "apply.yml lanzado en $Repo" -ForegroundColor Green
