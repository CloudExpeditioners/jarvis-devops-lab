# ---------------------------------------------------------------------------
# Service Bus: dos colas que desacoplan cada etapa
#   eventos-azure : Event Grid -> Function Centinela
#   jarvis-drift  : workflow drift-detect -> agente JARVIS (Copilot Studio)
# ---------------------------------------------------------------------------
resource "azurerm_servicebus_namespace" "sb" {
  name                = "sb-jarvis-${random_string.sufijo.result}"
  resource_group_name = azurerm_resource_group.jarvis.name
  location            = var.ubicacion
  sku                 = "Basic"
  minimum_tls_version = "1.2"
  local_auth_enabled  = true # necesario para el conector de Copilot Studio (SAS de solo escucha)
  tags                = local.tags
}

resource "azurerm_servicebus_queue" "eventos_azure" {
  name                  = "eventos-azure"
  namespace_id          = azurerm_servicebus_namespace.sb.id
  max_delivery_count    = 5
  default_message_ttl   = "P1D"
  lock_duration         = "PT1M"
}

resource "azurerm_servicebus_queue" "jarvis_drift" {
  name                = "jarvis-drift"
  namespace_id        = azurerm_servicebus_namespace.sb.id
  max_delivery_count  = 5
  default_message_ttl = "PT6H"
  lock_duration       = "PT1M"
}

# SAS de solo escucha para el disparador del agente: mínimo privilegio
resource "azurerm_servicebus_queue_authorization_rule" "copilot_listen" {
  name     = "copilot-listen"
  queue_id = azurerm_servicebus_queue.jarvis_drift.id
  listen   = true
  send     = false
  manage   = false
}

# ---------------------------------------------------------------------------
# Event Grid: escucha cada escritura/borrado exitoso en los RG de NeoBanco
# ---------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic" "suscripcion" {
  name                = "evgt-suscripcion-jarvis"
  resource_group_name = azurerm_resource_group.jarvis.name
  location            = "global"
  source_resource_id  = local.sub_scope
  topic_type          = "Microsoft.Resources.Subscriptions"
  identity { type = "SystemAssigned" }
  tags = local.tags
}

resource "azurerm_role_assignment" "eventgrid_envia" {
  scope                = azurerm_servicebus_queue.eventos_azure.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_eventgrid_system_topic.suscripcion.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_eventgrid_system_topic_event_subscription" "a_centinela" {
  name                          = "escrituras-neobanco"
  system_topic                  = azurerm_eventgrid_system_topic.suscripcion.name
  resource_group_name           = azurerm_resource_group.jarvis.name
  service_bus_queue_endpoint_id = azurerm_servicebus_queue.eventos_azure.id
  included_event_types          = ["Microsoft.Resources.ResourceWriteSuccess", "Microsoft.Resources.ResourceDeleteSuccess"]

  delivery_identity { type = "SystemAssigned" }

  advanced_filter {
    string_begins_with {
      key = "subject"
      values = [
        "${local.sub_scope}/resourceGroups/${local.rg_neobanco.hub}",
        "${local.sub_scope}/resourceGroups/${local.rg_neobanco.core}",
      ]
    }
  }

  retry_policy {
    max_delivery_attempts = 10
    event_time_to_live    = 60
  }

  depends_on = [azurerm_role_assignment.eventgrid_envia]
}
