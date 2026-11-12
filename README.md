# J.A.R.V.I.S. en modo DevOps

Un agente de IA que vigila la infraestructura de Azure de un banco **ficticio** ("NeoBanco"), detecta cuando alguien
la cambia a mano (**drift** de Terraform) y responde con **GitOps**: revierte lo crítico, propone un PR para lo
legítimo y **escala a una persona** lo que no conoce. Demo de la charla *"J.A.R.V.I.S. en modo DevOps: construyendo un
agente que administra mi cloud mientras duermo"* (AI Virtual Days 2026).

> ⚠️ **Es una demo de laboratorio, no una plataforma de producción.** Léete [Límites conocidos](docs/ARQUITECTURA.md#7-límites-conocidos-léelos-antes-de-copiar-el-diseño)
> antes de reutilizar nada. **No subas tus IDs de tenant/suscripción a un repositorio público**: trabaja en un repo privado propio.

## Qué hace (resultado medido)

Con tres cambios manuales (RDP abierto a internet, Storage público, SKU escalado), sin intervención humana:

| Resultado | Medido |
|---|---|
| NSG y Storage vuelven a lo que dice Git | ~5 min |
| El SKU **no** se revierte: se abre un PR para que un humano apruebe | ~4 min |
| Ticket con Síntoma / Causa / Solución aplicada / CI afectado + tarjeta en Teams | 5–6 min |
| Costo del agente (Copilot Studio) | 38–49 créditos por incidente |
| Un cambio que Terraform no gestiona (rol asignado a mano) | el agente **escala y no toca nada** |
| Un tag con una orden maliciosa para el agente | se trata como dato, se revierte y se reporta |

Son 1–2 corridas por escenario: úsalas como orden de magnitud, no como garantía.

## Documentación

| Documento | Para qué |
|---|---|
| [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md) | **Qué se usó, cómo funciona y por qué**, recurso por recurso, con guardrails y límites |
| [docs/RUNBOOK-IMPLEMENTACION.md](docs/RUNBOOK-IMPLEMENTACION.md) | Paso a paso para construirlo desde cero, con los errores reales que aparecieron |
| [docs/RUNBOOK-OPERACION.md](docs/RUNBOOK-OPERACION.md) | Operarlo: chequeos, leer un incidente, apagado de emergencia, limpieza, costos |
| [docs/politica-cambios-neobanco.pdf](docs/politica-cambios-neobanco.pdf) | La política (ficticia) que el agente aplica |

## Estructura

| Carpeta | Contenido |
|---|---|
| `bootstrap/` | Script único: estado de Terraform e identidades OIDC; configuración de GitHub |
| `infra/plataforma/` | Event Grid, Service Bus, Function, Key Vault, Policy, RBAC, presupuesto (lo aplica el equipo de plataforma) |
| `infra/neobanco/` | El banco: hub-spoke, App Service, SQL, Storage, Key Vault, Private Endpoints (lo aplica el pipeline) |
| `functions/jarvis/` | Function Centinela + servidor MCP con las 6 herramientas del agente |
| `.github/workflows/` | `plan`, `apply`, `drift-detect`, `reconcile`, `codify` |
| `scripts/` | Resumen y publicación del drift, guardrails, apagado (FinOps) |
| `chaos/` | Inyección del incidente (5 escenarios) y restauración |
| `copilot-studio/` | Instrucciones del agente, disparador y pruebas |

## Piezas principales

Azure (Event Grid, Service Bus, Functions Flex Consumption, Key Vault, Policy, App Service, SQL, Storage, Private Link) ·
Terraform · GitHub Actions con OIDC (sin secretos de larga duración) · GitHub App · Copilot Studio (agente + flujo de
trabajo) · Model Context Protocol · Teams.

## Por qué sin Flux ni ArgoCD

Son reconciliadores pensados para Kubernetes; aquí la infraestructura es PaaS con Terraform. Además, un reconciliador
ciego habría revertido también el escalado legítimo de capacidad. El valor del agente es el **criterio** previo a actuar.
El modelo es GitOps en *push* (GitHub Actions aplica `main`), con Git como única fuente de verdad.

## Empezar

Lee primero [docs/RUNBOOK-IMPLEMENTACION.md](docs/RUNBOOK-IMPLEMENTACION.md). Requiere una suscripción de Azure donde
seas Owner, GitHub, Teams y capacidad de Copilot Studio (pago por uso).

## Licencia

Sin licencia definida todavía: el autor debe elegir una antes de que otros reutilicen el código.
