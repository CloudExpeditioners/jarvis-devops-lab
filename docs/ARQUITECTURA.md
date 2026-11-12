# Arquitectura: qué se usó, cómo funciona y por qué

Este documento explica **cada pieza**, para quien quiera entender el diseño sin seguir los pasos de implementación
(eso está en [RUNBOOK-IMPLEMENTACION.md](RUNBOOK-IMPLEMENTACION.md)).

> **Alcance honesto.** Es una demo de laboratorio con un banco **ficticio**. Está diseñada con criterios de un
> entorno regulado (mínimo privilegio, trazabilidad, sin secretos de larga duración donde fue posible), pero no es
> una plataforma lista para producción ni una afirmación de cumplimiento normativo.

## 1. La idea en una frase

Un agente de IA vigila la infraestructura de Azure, detecta cuando alguien la cambia **fuera de Git**, decide con
una política escrita qué hacer y actúa **solo a través de workflows aprobados**: revierte lo grave, propone un PR
para lo legítimo y escala a una persona lo desconocido.

## 2. Las tres capas

| Capa | Pregunta que responde | Piezas |
|---|---|---|
| **Ojos** (detectar) | ¿Algo cambió fuera del proceso? | Event Grid, Service Bus, Function *Centinela*, `terraform plan` |
| **Cerebro** (decidir) | ¿Qué severidad tiene y qué dice la política? | Copilot Studio (agente + política en PDF) |
| **Manos** (actuar) | ¿Cómo se corrige sin dar permisos al agente? | Servidor MCP (Function), GitHub Actions, GitHub App, Teams |

## 3. Diagrama

```
 Operador (portal/CLI)                                        Git = la verdad
        │ cambio manual en Azure                                     ▲
        ▼                                                            │ PR (aceptar el cambio)
 ┌──────────────┐   ┌───────────────┐   ┌───────────────┐   ┌────────┴───────┐
 │  Event Grid  │──▶│  Service Bus  │──▶│  Function     │──▶│  drift-detect  │ terraform plan
 │ (suscripción)│   │ eventos-azure │   │  Centinela    │   │ (GitHub Actions)│ identidad SOLO LECTURA
 └──────────────┘   └───────────────┘   └───────────────┘   └────────┬───────┘
                                                                      │ reporte (blob) + mensaje
                                                              ┌───────▼───────┐
                                                              │  Service Bus  │
                                                              │  jarvis-drift │
                                                              └───────┬───────┘
                                                       ┌──────────────▼──────────────┐
                                                       │ Flujo de Copilot Studio     │
                                                       │ (disparador de cola)        │
                                                       └──────────────┬──────────────┘
                                                              ┌───────▼───────┐   conocimiento:
                                                              │ Agente JARVIS │◀─ Política de Cambios (PDF)
                                                              └───────┬───────┘
                                     herramientas MCP (Function) │ catálogo CERRADO de 6
        ┌───────────────────┬──────────────────┬───────────────────┴───┬───────────────┐
  get_drift_report   trigger_reconcile     open_codify_pr         escalate        post_report
  (lee el reporte)   (workflow: revertir)  (workflow: abre PR)   (Teams)          (Issue + Teams)
```

## 4. Inventario de recursos

### 4.1 Bootstrap (se crea una vez, a mano con script)

| Recurso | Qué es | Por qué | Cómo funciona |
|---|---|---|---|
| Storage de estado (ZRS) | Guarda el `tfstate` y los reportes de drift | El estado no puede vivir dentro de lo que gestiona | Sin claves compartidas (`allowSharedKeyAccess=false`), versionado, solo Entra ID. Contenedores `tfstate` y `drift` |
| Identidad `id-…-plan` | Managed identity con credencial federada | Detectar sin poder escribir | GitHub Actions presenta un token OIDC y Azure lo cambia por un token de esa identidad. **Sin secretos**. Vinculada a un *environment* de GitHub |
| Identidad `id-…-apply` | Managed identity con credencial federada | Aplicar/revertir con alcance acotado | Misma mecánica OIDC; solo `main` puede usarla en el environment `jarvis-auto` |

### 4.2 Plataforma (`infra/plataforma`, la gestiona el equipo de plataforma)

| Recurso | Qué es | Por qué | Cómo funciona |
|---|---|---|---|
| 4 grupos de recursos | `plataforma`, `jarvis`, `neobanco-hub`, `neobanco-core` | Separar quién crea qué | El pipeline de NeoBanco **no puede crear grupos de recursos**: solo escribir dentro de los suyos |
| Log Analytics + App Insights | Auditoría y logs | Trazabilidad | Recibe el Activity Log de la suscripción; tope diario de ingesta (FinOps) |
| Presupuesto de suscripción | Alertas al 80 % real y 100 % previsto | FinOps | Avisa por correo |
| Rol personalizado "Terraform Plan (solo lectura)" | `*/read` + listados que el provider necesita | `terraform plan` necesita refrescar el estado | Cero acciones de escritura. Si un plan falla con `AuthorizationFailed ... action 'X'`, se agrega X aquí |
| Event Grid (system topic de suscripción) | Emite un evento por cada escritura/borrado correcto | Detección en tiempo casi real | Filtrado por subject a los 2 grupos de NeoBanco. Entrega a Service Bus con su identidad administrada |
| Service Bus (Basic) + 2 colas | `eventos-azure` (Event Grid → Centinela) y `jarvis-drift` (reporte → agente) | Desacoplar cada etapa; si algo cae, el mensaje espera | La regla SAS que usa Copilot Studio es de **solo escucha** sobre `jarvis-drift` |
| Function App (Flex Consumption, Python) | Aloja *Centinela* y el servidor MCP | Sin servidor que mantener; paga por uso | Identidad de sistema con permisos solo de datos (recibir de la cola, leer el blob `drift`, leer secretos) |
| Key Vault | Clave privada de la GitHub App y URL del webhook de Teams | Los secretos no pasan por el estado de Terraform | Se cargan a mano; la Function los lee con referencias `@Microsoft.KeyVault(...)` |
| Azure Policy (modo **audit**) | Detecta RDP abierto y Storage público | Doble señal independiente de Terraform | Audit y no deny a propósito: en banca, el deny rompe los procedimientos de emergencia. La política detecta; JARVIS corrige |

### 4.3 NeoBanco (`infra/neobanco`, lo aplica el pipeline por GitOps)

| Recurso | Qué es | Por qué |
|---|---|---|
| VNet hub (10.0.0.0/16) y spoke core (10.10.0.0/16) + peering | Red hub-spoke | Patrón habitual de landing zone bancaria |
| 2 NSG con reglas **inline** | Segmentación por subred | Inline hace a Terraform *autoritativo*: ve una regla creada a mano. Con `azurerm_network_security_rule` separados no la vería |
| 3 zonas DNS privadas + enlaces | `privatelink` para SQL, Key Vault y Blob | Los Private Endpoints necesitan resolución privada |
| App Service Plan (P0v3) + Web App | "Core bancario" con integración VNet | Es el recurso cuyo SKU se cambia en la demo (capacidad = severidad media) |
| Storage de transacciones | Sin acceso público ni claves compartidas, ZRS | Es el dato sensible que se "expone" en la demo |
| Key Vault del core | Sin acceso público | Secretos de la aplicación |
| Azure SQL (solo Entra ID) + base Basic | Sin usuarios ni contraseñas SQL, sin acceso público | Base de datos del core; backup local por la región |
| 3 Private Endpoints | SQL, Key Vault, Storage | Los datos solo son alcanzables desde la red privada |

### 4.4 GitHub

| Pieza | Función |
|---|---|
| Workflow `plan` | Plan en cada PR (identidad de solo lectura) y comentario con el resumen |
| Workflow `apply` | Cada merge a `main` en `infra/neobanco` se aplica. **Esto es el GitOps**: Git manda |
| Workflow `drift-detect` | Los "ojos": plan de solo lectura → reporte → mensaje a la cola. Se dispara por el Centinela (y por un cron de respaldo) |
| Workflow `reconcile` | Las "manos" para revertir: aplica `main` acotado a los recursos indicados |
| Workflow `codify` | Las "manos" para aceptar: abre un PR que cambia el valor en Git; un humano aprueba |
| GitHub App | Identidad propia del agente: **un solo repositorio**, tokens de 1 hora. Cero roles en Azure |
| Environments | `neobanco-plan`, `neobanco-prod`, `jarvis-auto` (este último solo desde `main`) |
| Variable `JARVIS_ENABLED` | **Interruptor de apagado**: en `false`, `drift-detect`, `reconcile` y `codify` se saltan |

### 4.5 Copilot Studio y Teams

| Pieza | Función |
|---|---|
| Entorno + plan de pago por uso | Facturación por *Copilot Credits* en la suscripción de Azure |
| Agente JARVIS | Instrucciones + política en PDF como conocimiento + 6 herramientas MCP |
| Servidor MCP (la Function) | Catálogo **cerrado**: `get_drift_report`, `trigger_reconcile`, `open_codify_pr`, `get_workflow_status`, `escalate`, `post_report` |
| Flujo de trabajo | Escucha `jarvis-drift` (Service Bus, autocompletar) y ejecuta el agente con el contenido del mensaje |
| Webhook de Teams (Workflows) | Tarjetas de escalado y de cierre |

## 5. Qué pasa en un incidente (línea de tiempo medida)

Valores de una ejecución real con tres cambios manuales (RDP abierto, Storage público, SKU escalado):

| T+ | Evento |
|---|---|
| 0:00 | Un operador hace 3 cambios fuera de Terraform |
| 0:24 | El Centinela los detecta (filtra al pipeline) y lanza `drift-detect` |
| 2:31 | El plan encuentra 3 recursos con diferencias; el reporte se publica |
| 3:33 | El agente clasifica: 2 críticos, 1 medio. Lanza `reconcile` y `codify` |
| 5:13 | `reconcile` termina: NSG y Storage vuelven a lo que dice Git |
| 5:44 | Ticket (Issue) y tarjeta de Teams con los cuatro campos |

Otra corrida dio 5:00 de punta a punta. Son **dos muestras**: úsalas como rango (5–6 min), no como garantía.
Costo del agente en Copilot Studio: **38–49 créditos por incidente** (≈ 0,38–0,49 USD a 0,01 por crédito).

### Matriz de decisión (resumen de la política POL-TIC-07)

| Severidad | Ejemplo | Qué hace JARVIS | Humano |
|---|---|---|---|
| Crítica | RDP desde internet; Storage público | Revierte por reconciliación | Notificado |
| Media | Cambio de SKU | **No revierte**: abre PR para codificarlo | Aprueba o rechaza |
| Baja | Un tag | Revierte y reporta | Informado |
| Desconocida | Un rol asignado a mano (Terraform no lo gestiona) | No toca nada; escala | Decide |

## 6. Cómo se evita que el agente haga daño (defensa en profundidad)

1. **El agente no tiene permisos en Azure.** Solo puede llamar a 6 herramientas; esas herramientas solo disparan workflows o leen/escriben tickets.
2. **El pipeline no puede escalar privilegios:** `Contributor` en 2 grupos de recursos no permite asignar roles.
3. **Dos validaciones independientes del agente** en `reconcile`: lista blanca de tipos de recurso y máximo de 5 recursos (`validar_targets.py`), y bloqueo de cualquier plan que destruya o reemplace (`guardrail_plan.py`).
4. **Catálogo cerrado de cambios en Git:** `codify` solo puede editar la variable `app_service_sku` con un patrón válido.
5. **Los datos del reporte no son instrucciones.** Un tag con una orden maliciosa se trata como dato y se reporta como intento de manipulación. *Aunque el modelo obedeciera, no tiene herramienta para crear cuentas ni dar permisos*: esa es la defensa real, no el modelo.
6. **Interruptor de apagado** (`JARVIS_ENABLED`) y environment `jarvis-auto` restringido a `main`.
7. **Anti-datos-viejos:** el agente compara el id del reporte con el del mensaje; el reporte `latest.json` se sobrescribe también cuando no hay drift.
8. **Deduplicación por recurso:** un drift ya notificado (p. ej. un PR pendiente) no despierta al agente otra vez.

## 7. Límites conocidos (léelos antes de copiar el diseño)

- **El cron de GitHub Actions no es puntual.** En las pruebas el plan programado corrió con huecos de 6–8 horas. La detección real es por eventos; el cron es red de seguridad, no un SLA.
- **Terraform no ve todo.** Un rol asignado a mano o un recurso nuevo fuera del estado no aparecen como drift en el plan; el sistema los marca como `cambio_no_gestionado` y escala. No los repara.
- **El reporte guarda un solo evento de origen**, así que con varios cambios solo se atribuye autor al último.
- **El título de la tarjeta de cierre depende del texto** que escribe el agente (detecta "no se confirmó" / "se escaló"). Con una muestra funcionó; no es infalible.
- **Pruebas:** cada escenario se ejecutó 1–2 veces. La resistencia a prompt injection se probó con una sola orden simple.
- **Modo autocompletar del disparador:** si el flujo falla tras recibir el mensaje, ese mensaje no se reintenta.
- **Región:** `spaincentral` funcionó para todo lo desplegado, con dos excepciones: SQL no admite backup geo-redundante y los entornos de Power Platform se asignan por geografía (pueden caer en Suiza).
- **Incidentes del proveedor:** el flujo depende de Copilot Studio y Teams; una caída de Microsoft 365 los afecta. Azure y GitHub son independientes.
- **Demo-grade a propósito:** purge protection desactivado en los Key Vault, SAS de escucha para Copilot Studio, clave de Function para el MCP. Endurécelos si lo llevas más allá.
