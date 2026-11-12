data "azurerm_client_config" "actual" {}

# ---------------------------------------------------------------------------
# Cómputo: App Service con integración VNet, solo HTTPS, TLS 1.2
# ---------------------------------------------------------------------------
resource "azurerm_service_plan" "core" {
  name                = "asp-neobanco-core"
  resource_group_name = data.azurerm_resource_group.core.name
  location            = var.ubicacion
  os_type             = "Linux"
  sku_name            = var.app_service_sku
  tags                = merge(local.tags, { rol = "plan-core-banking" })
}

resource "azurerm_linux_web_app" "core" {
  name                      = "app-neobanco-core-${var.sufijo}"
  resource_group_name       = data.azurerm_resource_group.core.name
  location                  = var.ubicacion
  service_plan_id           = azurerm_service_plan.core.id
  https_only                = true
  virtual_network_subnet_id = azurerm_subnet.app.id
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  identity { type = "SystemAssigned" }

  site_config {
    minimum_tls_version    = "1.2"
    ftps_state             = "Disabled"
    vnet_route_all_enabled = true
    application_stack {
      python_version = "3.12"
    }
  }

  tags = merge(local.tags, { rol = "app-core-banking" })
}

# ---------------------------------------------------------------------------
# Datos: Storage de transacciones (sin acceso público, sin shared key)
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "transacciones" {
  name                            = "sttrx${var.sufijo}"
  resource_group_name             = data.azurerm_resource_group.core.name
  location                        = var.ubicacion
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  tags                            = merge(local.tags, { rol = "transacciones", clasificacion = "confidencial" })
}

resource "azurerm_key_vault" "core" {
  name                          = "kv-neobanco-${var.sufijo}"
  resource_group_name           = data.azurerm_resource_group.core.name
  location                      = var.ubicacion
  tenant_id                     = data.azurerm_client_config.actual.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled = true
  public_network_access_enabled = false
  soft_delete_retention_days    = 7
  purge_protection_enabled      = false # demo: permite destruir y recrear. En producción: true.
  tags                          = merge(local.tags, { rol = "secretos-core" })
}

resource "azurerm_mssql_server" "core" {
  name                          = "sql-neobanco-${var.sufijo}"
  resource_group_name           = data.azurerm_resource_group.core.name
  location                      = var.ubicacion
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false

  azuread_administrator {
    login_username              = var.sql_admin_login
    object_id                   = var.sql_admin_object_id
    azuread_authentication_only = true # sin usuarios SQL ni contraseñas
  }

  tags = merge(local.tags, { rol = "sql-core" })
}

resource "azurerm_mssql_database" "core" {
  name      = "sqldb-core-bancario"
  server_id = azurerm_mssql_server.core.id
  sku_name  = "Basic"
  # Spain Central no admite backup geo-redundante (ProvisioningDisabled): backup local
  storage_account_type = "Local"
  tags      = local.tags
}

# ---------------------------------------------------------------------------
# Private Endpoints: los datos solo son alcanzables desde la red privada
# ---------------------------------------------------------------------------
locals {
  endpoints = {
    sql  = { id = azurerm_mssql_server.core.id, subrecurso = "sqlServer", zona = "sql" }
    kv   = { id = azurerm_key_vault.core.id, subrecurso = "vault", zona = "kv" }
    blob = { id = azurerm_storage_account.transacciones.id, subrecurso = "blob", zona = "blob" }
  }
}

resource "azurerm_private_endpoint" "pe" {
  for_each            = local.endpoints
  name                = "pe-neobanco-${each.key}"
  resource_group_name = data.azurerm_resource_group.core.name
  location            = var.ubicacion
  subnet_id           = azurerm_subnet.data.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = each.value.id
    subresource_names              = [each.value.subrecurso]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-${each.key}"
    private_dns_zone_ids = [azurerm_private_dns_zone.zonas[each.value.zona].id]
  }
}

# Auditoría del Key Vault al Log Analytics de plataforma
resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "kv-a-law"
  target_resource_id         = azurerm_key_vault.core.id
  log_analytics_workspace_id = var.log_analytics_id
  enabled_log { category_group = "audit" }
}
