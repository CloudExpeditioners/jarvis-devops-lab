locals {
  tags = {
    proyecto   = "jarvis-devops"
    gestionado = "terraform-neobanco"
    entorno    = "prod-demo"
    banco      = "neobanco"
  }
}

data "azurerm_resource_group" "hub"  { name = "rg-neobanco-hub" }
data "azurerm_resource_group" "core" { name = "rg-neobanco-core" }

# ---------------------------------------------------------------------------
# Hub
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-neobanco-hub"
  resource_group_name = data.azurerm_resource_group.hub.name
  location            = var.ubicacion
  address_space       = ["10.0.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "hub_shared" {
  name                 = "snet-shared"
  resource_group_name  = data.azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ---------------------------------------------------------------------------
# Spoke: core bancario
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "core" {
  name                = "vnet-neobanco-core"
  resource_group_name = data.azurerm_resource_group.core.name
  location            = var.ubicacion
  address_space       = ["10.10.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = data.azurerm_resource_group.core.name
  virtual_network_name = azurerm_virtual_network.core.name
  address_prefixes     = ["10.10.1.0/24"]

  delegation {
    name = "webapps"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "data" {
  name                              = "snet-data"
  resource_group_name               = data.azurerm_resource_group.core.name
  virtual_network_name              = azurerm_virtual_network.core.name
  address_prefixes                  = ["10.10.2.0/24"]
  private_endpoint_network_policies = "Enabled" # los NSG también aplican a los Private Endpoints
}

resource "azurerm_virtual_network_peering" "hub_a_core" {
  name                      = "peer-hub-a-core"
  resource_group_name       = data.azurerm_resource_group.hub.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.core.id
  allow_forwarded_traffic   = true

  # Evita ReferencedResourceNotProvisioned: la VNet sigue "Updating" mientras se crean subnets y asociaciones de NSG
  depends_on = [
    azurerm_subnet.hub_shared,
    azurerm_subnet.app,
    azurerm_subnet.data,
    azurerm_subnet_network_security_group_association.app,
    azurerm_subnet_network_security_group_association.data,
  ]
}

resource "azurerm_virtual_network_peering" "core_a_hub" {
  name                      = "peer-core-a-hub"
  resource_group_name       = data.azurerm_resource_group.core.name
  virtual_network_name      = azurerm_virtual_network.core.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true

  # Evita ReferencedResourceNotProvisioned: la VNet sigue "Updating" mientras se crean subnets y asociaciones de NSG
  depends_on = [
    azurerm_subnet.hub_shared,
    azurerm_subnet.app,
    azurerm_subnet.data,
    azurerm_subnet_network_security_group_association.app,
    azurerm_subnet_network_security_group_association.data,
  ]
}

# ---------------------------------------------------------------------------
# NSG con reglas INLINE: así Terraform es autoritativo y detecta reglas
# creadas a mano (con azurerm_network_security_rule separados NO las vería).
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "app" {
  name                = "nsg-neobanco-app"
  resource_group_name = data.azurerm_resource_group.core.name
  location            = var.ubicacion
  tags                = merge(local.tags, { rol = "nsg-app" })

  security_rule {
    name                       = "permitir-https-desde-hub"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "10.0.0.0/16"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "denegar-internet-entrante"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "data" {
  name                = "nsg-neobanco-data"
  resource_group_name = data.azurerm_resource_group.core.name
  location            = var.ubicacion
  tags                = merge(local.tags, { rol = "nsg-data" })

  security_rule {
    name                       = "permitir-app-a-datos"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "1433"]
    source_address_prefix      = "10.10.1.0/24"
    destination_address_prefix = "10.10.2.0/24"
  }

  security_rule {
    name                       = "denegar-todo-entrante"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_subnet_network_security_group_association" "data" {
  subnet_id                 = azurerm_subnet.data.id
  network_security_group_id = azurerm_network_security_group.data.id
}

# ---------------------------------------------------------------------------
# DNS privado (en el hub, enlazado a ambas VNets)
# ---------------------------------------------------------------------------
locals {
  zonas_privadas = {
    sql  = "privatelink.database.windows.net"
    kv   = "privatelink.vaultcore.azure.net"
    blob = "privatelink.blob.core.windows.net"
  }
}

resource "azurerm_private_dns_zone" "zonas" {
  for_each            = local.zonas_privadas
  name                = each.value
  resource_group_name = data.azurerm_resource_group.hub.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each              = azurerm_private_dns_zone.zonas
  name                  = "link-hub"
  resource_group_name   = data.azurerm_resource_group.hub.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.hub.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "core" {
  for_each              = azurerm_private_dns_zone.zonas
  name                  = "link-core"
  resource_group_name   = data.azurerm_resource_group.hub.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.core.id
}
