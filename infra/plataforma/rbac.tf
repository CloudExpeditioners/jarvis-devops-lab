# ---------------------------------------------------------------------------
# Rol personalizado para "terraform plan": lectura + las acciones de listado que
# el provider azurerm necesita para refrescar el estado. Sin permisos de escritura.
# Si un plan falla con AuthorizationFailed, el error nombra la acción: agrégala aquí.
# ---------------------------------------------------------------------------
resource "azurerm_role_definition" "terraform_plan" {
  name        = "NeoBanco Terraform Plan (solo lectura)"
  scope       = local.sub_scope
  description = "Lectura para terraform plan. Sin escritura. Usado por id-jarvis-plan."

  permissions {
    actions = [
      "*/read",
      "Microsoft.Web/sites/config/list/action",
      "Microsoft.Web/sites/publishxml/action",
      # Las cuentas de storage tienen shared key deshabilitado: listar claves no da acceso a datos.
      "Microsoft.Storage/storageAccounts/listKeys/action",
    ]
    not_actions = []
  }
  assignable_scopes = [local.sub_scope]
}

# --- Identidad de PLAN (detección de drift) ---
resource "azurerm_role_assignment" "plan_neobanco" {
  for_each           = azurerm_resource_group.neobanco
  scope              = each.value.id
  role_definition_id = azurerm_role_definition.terraform_plan.role_definition_resource_id
  principal_id       = var.plan_principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "plan_plataforma_reader" {
  scope                = azurerm_resource_group.plataforma.id
  role_definition_name = "Reader"
  principal_id         = var.plan_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "plan_envia_a_jarvis" {
  scope                = azurerm_servicebus_queue.jarvis_drift.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = var.plan_principal_id
  principal_type       = "ServicePrincipal"
}

# --- Identidad de APPLY (pipeline y reconcile): escritura SOLO en los RG de NeoBanco ---
resource "azurerm_role_assignment" "apply_neobanco" {
  for_each             = azurerm_resource_group.neobanco
  scope                = each.value.id
  role_definition_name = "Contributor"
  principal_id         = var.apply_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "apply_law" {
  scope                = azurerm_log_analytics_workspace.law.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = var.apply_principal_id
  principal_type       = "ServicePrincipal"
}
