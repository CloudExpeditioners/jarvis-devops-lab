locals {
  sub_scope = "/subscriptions/${var.subscription_id}"
  tags = {
    proyecto   = "jarvis-devops"
    gestionado = "terraform-plataforma"
    entorno    = "demo"
  }
  rg_neobanco = {
    hub  = "rg-neobanco-hub"
    core = "rg-neobanco-core"
  }
  tfstate_sa_name = element(split("/", var.tfstate_sa_id), length(split("/", var.tfstate_sa_id)) - 1)
}

resource "random_string" "sufijo" {
  length  = 5
  upper   = false
  special = false
}

# ---------------------------------------------------------------------------
# Grupos de recursos: plataforma (equipo cloud) vs. carga de trabajo (NeoBanco)
# El pipeline de NeoBanco NO puede crear grupos de recursos: solo escribir dentro de estos.
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "plataforma" {
  name     = "rg-plataforma"
  location = var.ubicacion
  tags     = local.tags
}

resource "azurerm_resource_group" "jarvis" {
  name     = "rg-jarvis"
  location = var.ubicacion
  tags     = local.tags
}

resource "azurerm_resource_group" "neobanco" {
  for_each = local.rg_neobanco
  name     = each.value
  location = var.ubicacion
  tags     = merge(local.tags, { gestionado = "terraform-neobanco" })
}

# ---------------------------------------------------------------------------
# Observabilidad y auditoría
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "log-neobanco"
  resource_group_name = azurerm_resource_group.plataforma.name
  location            = var.ubicacion
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 1 # FinOps: techo de ingesta diaria para la demo
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name                       = "activity-log-a-law"
  target_resource_id         = local.sub_scope
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  enabled_log { category = "Administrative" }
  enabled_log { category = "Policy" }
  enabled_log { category = "Security" }
}

resource "azurerm_application_insights" "jarvis" {
  name                = "appi-jarvis"
  resource_group_name = azurerm_resource_group.jarvis.name
  location            = var.ubicacion_funciones
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "other"
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Presupuesto (FinOps)
# ---------------------------------------------------------------------------
resource "azurerm_consumption_budget_subscription" "demo" {
  name            = "presupuesto-jarvis-demo"
  subscription_id = local.sub_scope
  amount          = var.presupuesto_usd
  time_grain      = "Monthly"
  time_period { start_date = var.presupuesto_inicio }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.email_alertas]
  }
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.email_alertas]
  }
}
