# Runbook de implementación (paso a paso)

Tiempo: 1–2 días de trabajo la primera vez. Comandos para **Windows + PowerShell** (también valen en macOS/Linux con
ajustes menores). Los nombres de los menús de Microsoft cambian con frecuencia: si algo no coincide, busca la opción
equivalente.

> **Regla de oro:** trabaja en un repositorio **privado propio**. El Terraform de NeoBanco necesita tus IDs reales en
> `terraform.tfvars` para que el pipeline funcione. **Nunca los subas a un repositorio público.**

## 0. Requisitos

- Una suscripción de Azure donde seas **Owner** y un tenant con permisos para crear identidades y registros de aplicación.
- Cuenta de GitHub (repo privado, Actions habilitado).
- Microsoft Teams (para el canal de alertas) y acceso a Power Platform / Copilot Studio.
- Si tu tenant exige MFA para operaciones de permisos, ten el segundo factor a mano: **borrar asignaciones de rol vuelve a pedirlo**.

Herramientas locales:

```powershell
winget install -e --id Microsoft.AzureCLI
winget install -e --id Hashicorp.Terraform
winget install -e --id GitHub.cli
winget install -e --id Git.Git
winget install -e --id Python.Python.3.11
winget install -e --id Microsoft.Azure.FunctionsCoreTools
```

Cierra y abre la terminal. Necesitas: Azure CLI reciente (una versión de 2023 no conoce regiones ni servicios nuevos),
Terraform ≥ 1.9, Functions Core Tools 4.x. El Python local no importa: la Function se compila en Azure (3.11).

```powershell
az login ; gh auth login
az account set --subscription "<id-de-tu-suscripcion>"
```

## 1. Repositorio privado (primero)

Crea el repo **antes** del bootstrap: necesitas su ID para la credencial OIDC si tu cuenta usa subject con IDs.

```powershell
git init -b main
terraform fmt -recursive
git add . ; git commit -m "JARVIS: estructura inicial"
gh repo create <tu-usuario>/jarvis-devops --private --source . --push
```

El primer push dispara `apply.yml` y **fallará**: aún no hay variables ni valores reales. Es esperado.

## 2. Bootstrap de Azure (una sola vez)

```powershell
cd bootstrap
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\bootstrap.ps1 -SubscriptionId "<id>" -GitHubOwner "<tu-usuario>" -GitHubRepo "jarvis-devops"
```

Crea: providers registrados (incluido `Microsoft.PowerPlatform`), Storage del estado, y las dos identidades con
credencial federada. Guarda los valores en `bootstrap\salida-bootstrap.json` (está en `.gitignore`).

> **Si más adelante el login OIDC falla con `AADSTS700213 No matching federated identity record`**, el error muestra el
> subject real. Si trae IDs numéricos (`repo:owner@123/repo@456:...`), vuelve a ejecutar con `-SubjectConIds`
> (o corrige las tres credenciales con `az identity federated-credential update`).

Región por defecto: `spaincentral`. Si algún servicio no está disponible, usa `-Location westeurope`.

## 3. GitHub App (identidad del agente en GitHub)

GitHub → Settings → Developer settings → **GitHub Apps → New GitHub App**.

- Webhook: **desmarca "Active"**.
- Permisos de repositorio: **Actions** R/W, **Contents** R/W, **Issues** R/W, **Pull requests** R/W, Metadata R.
- Instalable solo en tu cuenta. Crea la App, anota el **App ID**, genera una **clave privada** (.pem) y guárdala **fuera del repo**.
- **Install App** → solo el repositorio `jarvis-devops`. Anota el **Installation ID** (número final de la URL).

## 4. Canal y webhook de Teams

En el canal: ⋯ → **Workflows** → plantilla *Send webhook alerts to a channel* → copia la URL. (Los antiguos
"Incoming Webhooks" de Office 365 están retirados.) Guárdala en un archivo local, **no la pegues en chats ni en Git**.

Prueba:

```powershell
$url = Get-Content ruta\teams-webhook.txt -Raw
$card = '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","version":"1.4","body":[{"type":"TextBlock","text":"JARVIS en línea","weight":"Bolder"}]}}]}'
Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Body $card
```

## 5. Plataforma (Terraform en local)

```powershell
cd infra\plataforma
Copy-Item terraform.tfvars.example terraform.tfvars
Copy-Item backend.hcl.example backend.hcl
# completa ambos con salida-bootstrap.json, los IDs de la GitHub App y tu correo
terraform init '-backend-config=backend.hcl'     # las comillas son OBLIGATORIAS en PowerShell
terraform plan -out tfplan
terraform apply tfplan
terraform output
```

Anota `sufijo`, `function_app_name`, `key_vault_jarvis`, `log_analytics_id`, `servicebus_fqdn`.
Si la Function falla por región (Flex Consumption), cambia `ubicacion_funciones` (p. ej. `swedencentral`) y repite.

## 6. Secretos y código de la Function

```powershell
$kv = terraform output -raw key_vault_jarvis
az keyvault secret set --vault-name $kv -n github-app-private-key --file ruta\clave-app.pem
az keyvault secret set --vault-name $kv -n teams-webhook-url --file ruta\teams-webhook.txt
az functionapp restart -g rg-jarvis -n <function_app_name>   # para que lea las referencias a Key Vault

cd ..\..\functions\jarvis
func azure functionapp publish <function_app_name> --python
```

Si `secret set` da 403, espera 2–3 minutos (propagación del rol).

Prueba el servidor MCP (debe listar 6 herramientas):

```powershell
$mcp = "https://<function_app_name>.azurewebsites.net/api/mcp"
$key = az functionapp keys list -g rg-jarvis -n <function_app_name> --query functionKeys.default -o tsv
$b = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
(Invoke-RestMethod -Method Post -Uri $mcp -Headers @{ "x-functions-key" = $key } -ContentType "application/json" -Body $b).result.tools | Select-Object name
```

Prueba que la Function habla con GitHub y Teams (debe devolver `{"notificado": true}` y dejar una tarjeta):

```powershell
$b2 = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"escalate","arguments":{"resumen":"Prueba de conexión","severidad":"prueba"}}}'
(Invoke-RestMethod -Method Post -Uri $mcp -Headers @{ "x-functions-key" = $key } -ContentType "application/json" -Body $b2).result.content[0].text
```

## 7. Variables, secretos y environments de GitHub

```powershell
cd ..\..\bootstrap
.\configurar-github.ps1 -GitHubOwner "<tu-usuario>" -GitHubRepo "jarvis-devops" -GitHubAppId "<APP_ID>" -RutaClavePrivadaApp "ruta\clave-app.pem"
```

Crea 10 variables (`JARVIS_ENABLED=true`, `MAX_TARGETS=5`…), el secreto de la App, los 3 environments y los labels.
Deja la protección de `main` para después del primer despliegue.

## 8. Desplegar NeoBanco por GitOps

1. Edita `infra/neobanco/terraform.tfvars`: `sufijo` (salida de plataforma), `sql_admin_login`, `sql_admin_object_id`
   (tu usuario o un grupo de Entra ID) y `log_analytics_id`.
2. Rama, commit y PR:

```powershell
git checkout -b despliegue-inicial
git add infra/neobanco ; git commit -m "NeoBanco: valores del entorno"
git push -u origin despliegue-inicial
gh pr create --repo <tu-usuario>/jarvis-devops --base main --title "Despliegue inicial" --body "Primer despliegue por GitOps"
gh pr checks <n> --watch --repo <tu-usuario>/jarvis-devops
gh pr view <n> --comments --repo <tu-usuario>/jarvis-devops
```

3. El comentario debe decir ~`Plan: 30 to add`. **Apaga a JARVIS antes del merge** (`gh variable set JARVIS_ENABLED --body false`)
   para que no reporte drift falso mientras el banco se construye. Haz merge; `apply.yml` tarda 10–15 min.
4. Verifica: peerings `Connected`, base SQL creada, Storage `publicNetworkAccess=Disabled`, NSG con 2 reglas.

Fallos que aparecieron en este paso (ya corregidos en el código):

| Error | Causa | Solución |
|---|---|---|
| `AADSTS700213` en `terraform init` del pipeline | Subject OIDC con IDs | `-SubjectConIds` / actualizar credenciales |
| `ProvisioningDisabled: geo-redundant storage` | Spain Central no admite backup geo-redundante | `storage_account_type = "Local"` |
| `ReferencedResourceNotProvisioned ... PutSubnetOperation` | Peering creado mientras la VNet se actualiza | `depends_on` en los peerings |

## 9. Prueba en seco (sin agente)

```powershell
gh variable set JARVIS_ENABLED --body true --repo <tu-usuario>/jarvis-devops
gh workflow run drift-detect.yml --repo <tu-usuario>/jarvis-devops   # con el banco limpio debe dar tipo=sin_cambios
cd chaos ; .\inyectar-caos.ps1 -Escenarios rdp
```

Espera ~3 min. Debe aparecer un `drift-detect` por `repository_dispatch`, el reporte `tipo=drift` y un mensaje en la cola
`jarvis-drift`. Revierte a mano para comprobar las "manos":

```powershell
gh workflow run reconcile.yml --repo <tu-usuario>/jarvis-devops -f targets="azurerm_network_security_group.app" -f severidad=critica -f justificacion="prueba en seco"
```

Vacía la cola antes de conectar el agente (ver RUNBOOK-OPERACION → "Vaciar la cola").

## 10. Copilot Studio

### 10.1 Plan de pago por uso y entorno (el paso donde más tiempo se pierde)

1. Registra el proveedor: `az provider register --namespace Microsoft.PowerPlatform --wait`.
2. **Crea el entorno primero** (centro de administración de Power Platform → Entornos → Nuevo): Producción, **Dataverse = Sí**,
   grupo de seguridad "Ninguno". Con la geografía "Unión Europea y EFTA" el sistema elige la región **solo** (en estas
   pruebas cayó en Suiza). **Mira la columna Región del entorno ya creado.**
3. **Crea el plan de facturación en esa misma región** (Licencias → Planes de facturación → Nuevo; suscripción, grupo de
   recursos, producto Copilot Studio; nombre solo con letras). Si el plan está en otra región, al agregar entornos la lista
   sale vacía y la región del entorno **no se puede cambiar**.
4. Abre el plan → **Agregar entornos** → marca el entorno.

### 10.2 Agente

1. copilotstudio.microsoft.com → selector de entorno (abajo a la izquierda) → el del plan. En el entorno predeterminado no habría facturación.
2. Agentes → **Agente** → nombre `JARVIS`. Quita **Work IQ** (Herramientas) y **Buscar en todos los sitios web** (Conocimiento).
3. Pega las instrucciones de [`copilot-studio/instrucciones-agente.md`](../copilot-studio/instrucciones-agente.md).
4. **Conocimiento → +** → sube `docs/politica-cambios-neobanco.pdf`; espera *Listo*. Mejora la descripción: "Política de Gestión de Cambios (matriz de severidad, respuesta de JARVIS, guardrails, formato de cierre). Consultar siempre antes de decidir."
5. **Herramientas → + → pestaña MCP → Agregar → Model Context Protocol**:
   - Nombre `jarvis-neobanco-tools`; URL `https://<function_app_name>.azurewebsites.net/api/mcp`.
   - Autenticación **Clave API**, parámetro **Encabezado**, nombre `x-functions-key`.
   - Crea la conexión pegando la clave (cópiala justo antes: `az functionapp keys list ... | Set-Clipboard`).
   - En el editor de la herramienta, **Autenticación = Cuenta compartida** (con el disparador autónomo no hay usuario final). Verás 6 herramientas. Un aviso de "no pudimos cargar el contrato" apareció sin consecuencias.
6. Guarda y prueba en **Probar**: ver [`pruebas-agente.md`](../copilot-studio/pruebas-agente.md).

### 10.3 Disparador autónomo

Sigue [`copilot-studio/prompt-disparador.md`](../copilot-studio/prompt-disparador.md): **publica el agente**, crea un flujo con el
conector de Service Bus (autenticación *Access Key*), nodo Agente con el valor **Contenido** y publica el flujo.

## 11. Prueba autónoma completa

Con el banco limpio, `JARVIS_ENABLED=true`, cola en 0 y el flujo publicado:

```powershell
cd chaos
.\inyectar-caos.ps1 -Escenarios rdp,storage,escalado     # anota la hora de inicio
```

No toques nada ~7 minutos. Esperado: NSG con 2 reglas, Storage `Disabled`, plan en `P1v3` (el agente **no** lo revierte),
un PR de JARVIS con `app_service_sku=P1v3`, un Issue con los cuatro campos y **una** tarjeta de cierre en Teams.

Otros escenarios: `-Escenarios inyeccion` (el agente no obedece la orden del tag) y `-Escenarios rolstorage`
(Terraform no lo gestiona: el agente **escala** y no toca nada; requiere MFA reciente).

Limpieza tras cada prueba: cierra el PR y el Issue sin fusionar, ejecuta `apply.yml` (devuelve el SKU a lo que dice Git)
y confirma `sin_cambios`. Detalle en [RUNBOOK-OPERACION.md](RUNBOOK-OPERACION.md).

## 12. Solución de problemas

| Síntoma | Causa probable y solución |
|---|---|
| `terraform init` en PowerShell: *Too many command line arguments* | Falta entrecomillar: `terraform init '-backend-config=backend.hcl'` |
| Plan del pipeline: `AuthorizationFailed ... action 'X'` | Agrega X al rol personalizado en `infra/plataforma/rbac.tf` |
| Primer comentario del PR dice `2 to change` y el segundo `No changes` | El primer plan corrió mientras `reconcile` aún corregía; vale el segundo |
| El agente lee un drift viejo | `latest.json` desactualizado: ejecuta `drift-detect` con el banco limpio (el script lo sobrescribe) |
| El agente pregunta "¿lo hago ya?" y no actúa | Falta el principio 6 de las instrucciones (modo autónomo) |
| El agente escala diciendo que no pudo confirmar el run | `get_workflow_status` debe esperar dentro de la Function (versión actual) |
| `az role assignment delete` → `AADSTS50076` | Tu tenant exige MFA: `az login --tenant <id> --scope https://management.core.windows.net//.default --claims-challenge "<el que muestra el error>"` |
| Rol creado pero el envío a la cola sigue `Unauthorized` | Propagación lenta de Service Bus (varios minutos) |
| "Ejecutar nodo" del flujo da *Sin drift* aunque hay mensaje | Esa prueba recibe contenido vacío; prueba publicando el flujo |
| Crear regla de firewall SQL: `DenyPublicEndpointEnabled` | Azure lo bloquea mientras el SQL tenga acceso público deshabilitado (no es un fallo) |
| No aparece ejecución del flujo | Cola con permiso de solo escucha: escribe `jarvis-drift` a mano; revisa la conexión Access Key |
| El cron de `drift-detect` no corre cada 30 min | GitHub Actions no garantiza puntualidad; la detección real es por eventos |
