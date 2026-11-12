# Runbook de operación

Qué hacer **cuando el sistema ya está desplegado**: chequeos, cómo leer un incidente, apagado de emergencia, limpieza,
costos y rotación de credenciales. Sustituye `<owner>/<repo>` por tu repositorio.

## 1. Chequeo de salud (solo lectura, 1 minuto)

```powershell
gh variable list --repo <owner>/<repo> | Select-String "JARVIS_ENABLED"
az network nsg show -g rg-neobanco-core -n nsg-neobanco-app --query "securityRules[].name" -o tsv
az storage account show -g rg-neobanco-core -n <storage-transacciones> --query publicNetworkAccess -o tsv
az appservice plan show -g rg-neobanco-core -n asp-neobanco-core --query sku.name -o tsv
az servicebus queue show -g rg-jarvis --namespace-name <sb> -n jarvis-drift --query "countDetails.activeMessageCount"
gh pr list --repo <owner>/<repo> ; gh issue list --repo <owner>/<repo>
```

Estado sano: `true`, 2 reglas de NSG, `Disabled`, `P0v3`, cola en `0`, ningún PR ni Issue abierto.

## 2. Leer un incidente

1. **Teams:** una tarjeta de cierre (verde = resuelto; ámbar = escalado, requiere revisión humana). Una alerta de escalado previa es normal.
2. **Issue** (`incidente`, `jarvis`): Síntoma / Causa / Solución aplicada / CI afectado.
3. **PR de JARVIS** (solo si el cambio es de capacidad/SKU): *aprobar* = Git pasa a reflejar la realidad; *rechazar* = cierra el PR.
   Rechazar **no** revierte el cambio: Azure conserva el valor actual hasta que una persona decida.
4. **Copilot Studio → Flujos de trabajo → JARVIS - disparador drift → Actividad:** hora, duración, créditos y respuesta del agente.

Si el agente **escaló** (severidad desconocida o un guardrail rechazó): no hay corrección automática. Valida el cambio
(¿quién, qué rol, qué alcance?), y decide: eliminarlo, o codificarlo en Terraform por PR.

## 3. Apagado de emergencia (kill switch)

```powershell
gh variable set JARVIS_ENABLED --body false --repo <owner>/<repo>
```

Con `false` se saltan `drift-detect`, `reconcile` y `codify`. El agente puede seguir recibiendo mensajes pero sus
herramientas de acción no producen cambios. Para despublicar el flujo: Copilot Studio → el flujo → ⋯ → desactivar.
Vuelve a `true` solo cuando hayas entendido qué pasó.

## 4. Limpieza tras un ensayo

```powershell
gh pr close <n> --delete-branch --repo <owner>/<repo>
gh issue close <n> --reason "not planned" --repo <owner>/<repo>
gh workflow run apply.yml --repo <owner>/<repo>       # devuelve el SKU a lo que dice Git
# esperar el apply, luego:
gh workflow run drift-detect.yml --repo <owner>/<repo>
```

Confirma que `latest.json` dice `sin_cambios` y la cola está en 0:

```powershell
az storage blob download --account-name <sa-bootstrap> -c drift -n latest.json --auth-mode login -f "$env:TEMP\latest.json" --no-progress -o none
(Get-Content "$env:TEMP\latest.json" -Raw | ConvertFrom-Json) | Select-Object id, tipo, total_recursos
```

## 5. Quitar un permiso que dejaste puesto (p. ej. el escenario `rolstorage`)

Borrar una asignación de rol **también genera un evento** que el Centinela detecta. Orden correcto:

1. Apaga a JARVIS: `gh variable set JARVIS_ENABLED --body false`.
2. Inicia sesión con MFA si Azure lo exige y borra el rol (`chaos\restaurar.ps1 -QuitarRolStorage`).
3. Espera ~3 minutos.
4. Enciende: `JARVIS_ENABLED=true`, cierra el Issue de la prueba, ejecuta `drift-detect` y comprueba `sin_cambios`.

## 6. Vaciar la cola `jarvis-drift`

Necesario antes de publicar el flujo o tras pruebas manuales (si no, el agente procesaría mensajes viejos y duplicaría tickets).
La cadena de escucha ya tiene permiso para recibir y borrar:

```powershell
cd infra\plataforma
$env:SB_CONN = terraform output -raw copilot_servicebus_connection_string
python -m pip install azure-servicebus
@'
import os
from azure.servicebus import ServiceBusClient, ServiceBusReceiveMode
n = 0
with ServiceBusClient.from_connection_string(os.environ["SB_CONN"]) as c:
    with c.get_queue_receiver("jarvis-drift", receive_mode=ServiceBusReceiveMode.RECEIVE_AND_DELETE) as r:
        while True:
            m = r.receive_messages(max_message_count=50, max_wait_time=5)
            if not m: break
            n += len(m)
print("Mensajes borrados:", n)
'@ | Set-Content -Path vaciar_cola.py -Encoding ascii
python vaciar_cola.py
Remove-Item Env:SB_CONN
```

## 7. Apagar el banco entre sesiones (FinOps)

El banco (App Service y Private Endpoints) es lo que más cuesta. La plataforma cuesta poco y puede quedarse.

```powershell
.\scripts\apagar-todo.ps1 -Repo <owner>/<repo>      # apaga a JARVIS y destruye NeoBanco
# para volver:
gh variable set JARVIS_ENABLED --body true --repo <owner>/<repo>
gh workflow run apply.yml --repo <owner>/<repo>      # ~15 min
```

**Costos.** Medido: el agente consume **38–49 créditos por incidente** (≈ 0,38–0,49 USD a 0,01 por crédito en pago por uso);
una consulta simple ≈ 10 créditos. **Estimado (no medido):** NeoBanco más la plataforma encendidos cuestan del orden de
0,13 USD por hora (~100 USD al mes 24/7); confírmalo con la calculadora de precios de Azure y tu factura. El presupuesto de
Terraform avisa por correo. Con el repo privado, el cron de `drift-detect` consume minutos de GitHub Actions mientras
`JARVIS_ENABLED=true`.

## 8. Rotación de credenciales

| Credencial | Dónde vive | Cómo rotarla |
|---|---|---|
| Clave de la Function (MCP) | Conexión de Copilot Studio | `az functionapp keys set` y actualiza la conexión de la herramienta |
| Clave privada de la GitHub App | Key Vault + secreto de GitHub | Genera otra en la App, actualiza ambos, reinicia la Function |
| Webhook de Teams | Key Vault | Crea un flujo nuevo, actualiza el secreto, reinicia la Function |
| Cadena SAS de escucha (Service Bus) | Conexión del flujo de Copilot Studio | Regenera la clave de la regla `copilot-listen` y actualiza la conexión |
| OIDC (GitHub → Azure) | Sin secretos | Nada que rotar; si cambias de repo, actualiza el subject |

## 9. Si cae un proveedor

- **Copilot Studio / Teams (Microsoft 365):** el flujo no consume la cola o las tarjetas no llegan. Los mensajes esperan en
  `jarvis-drift` (TTL de 6 h). Al recuperarse, revisa que no haya mensajes obsoletos antes de dejar que el agente los procese.
- **GitHub Actions:** no hay reconciliación ni plan; el Centinela sigue encolando señales.
- **Azure:** Event Grid y Service Bus reintentan la entrega.
- **Plan B de una demo:** un video grabado de una ejecución completa.
