# ---------------------------------------------------------------------------
# Key Vault de JARVIS: secretos que NO pasan por el estado de Terraform.
# Los cargas tú a mano (GUIA paso 6): clave privada de la GitHub App y URL del webhook de Teams.
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "jarvis" {
  name                       = "kv-jarvis-${random_string.sufijo.result}"
  resource_group_name        = azurerm_resource_group.jarvis.name
  location                   = var.ubicacion
  tenant_id                  = data.azurerm_client_config.actual.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # demo: permite destruir y recrear. En producción: true.
  tags                       = local.tags
}

data "azurerm_client_config" "actual" {}

resource "azurerm_role_assignment" "yo_kv" {
  scope                = azurerm_key_vault.jarvis.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.mi_usuario_object_id
  principal_type       = "User"
}

# ---------------------------------------------------------------------------
# Function App (Flex Consumption): Centinela + servidor MCP de herramientas
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "func" {
  name                            = "stjarvisfn${random_string.sufijo.result}"
  resource_group_name             = azurerm_resource_group.jarvis.name
  location                        = var.ubicacion_funciones
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

resource "azurerm_storage_container" "deploy" {
  name                  = "deploy"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}

resource "azurerm_service_plan" "flex" {
  name                = "asp-jarvis-flex"
  resource_group_name = azurerm_resource_group.jarvis.name
  location            = var.ubicacion_funciones
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

resource "azurerm_function_app_flex_consumption" "jarvis" {
  name                = "func-jarvis-${random_string.sufijo.result}"
  resource_group_name = azurerm_resource_group.jarvis.name
  location            = var.ubicacion_funciones
  service_plan_id     = azurerm_service_plan.flex.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.func.primary_blob_endpoint}${azurerm_storage_container.deploy.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.func.primary_access_key

  runtime_name           = "python"
  runtime_version        = "3.11"
  maximum_instance_count = 40
  instance_memory_in_mb  = 2048
  https_only             = true

  identity { type = "SystemAssigned" }

  site_config {
    application_insights_connection_string = azurerm_application_insights.jarvis.connection_string
  }

  app_settings = {
    # Centinela
    "ServiceBusConnection__fullyQualifiedNamespace" = "${azurerm_servicebus_namespace.sb.name}.servicebus.windows.net"
    "PRINCIPALES_IGNORADOS"                         = "${var.plan_principal_id},${var.apply_principal_id}"
    "RG_GESTIONADOS"                                = "${local.rg_neobanco.hub},${local.rg_neobanco.core}"
    # GitHub (la clave privada vive en Key Vault)
    "GITHUB_OWNER"               = var.github_owner
    "GITHUB_REPO"                = var.github_repo
    "GITHUB_APP_ID"              = var.github_app_id
    "GITHUB_APP_INSTALLATION_ID" = var.github_app_installation_id
    "GITHUB_APP_PRIVATE_KEY"     = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.jarvis.name};SecretName=github-app-private-key)"
    "TEAMS_WEBHOOK_URL"          = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.jarvis.name};SecretName=teams-webhook-url)"
    # Herramientas del agente
    "DRIFT_BLOB_URL"      = "https://${local.tfstate_sa_name}.blob.core.windows.net/drift/latest.json"
    "MAX_TARGETS"         = tostring(var.max_targets)
    "RECONCILE_ALLOWLIST" = "azurerm_network_security_group.,azurerm_storage_account.,azurerm_key_vault.,azurerm_mssql_server.,azurerm_linux_web_app.,azurerm_private_endpoint.,azurerm_virtual_network."
  }

  tags = local.tags
}

# Permisos de la Function: solo datos, ningún rol de escritura sobre recursos de Azure
resource "azurerm_role_assignment" "func_lee_eventos" {
  scope                = azurerm_servicebus_queue.eventos_azure.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_function_app_flex_consumption.jarvis.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "func_lee_drift" {
  scope                = "${var.tfstate_sa_id}/blobServices/default/containers/drift"
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_function_app_flex_consumption.jarvis.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "func_lee_secretos" {
  scope                = azurerm_key_vault.jarvis.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_function_app_flex_consumption.jarvis.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
