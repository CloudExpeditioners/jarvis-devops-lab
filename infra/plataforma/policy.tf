# ---------------------------------------------------------------------------
# Azure Policy en modo AUDIT (no deny) a propósito: en banca el deny rompe los
# procedimientos de break-glass. La política detecta; JARVIS corrige.
# ---------------------------------------------------------------------------
resource "azurerm_policy_definition" "storage_publico" {
  name         = "neobanco-audit-storage-publico"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "NeoBanco: auditar storage con acceso de red público"
  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Storage/storageAccounts" },
        { field = "Microsoft.Storage/storageAccounts/publicNetworkAccess", notEquals = "Disabled" }
      ]
    }
    then = { effect = "audit" }
  })
}

resource "azurerm_policy_definition" "nsg_rdp_internet" {
  name         = "neobanco-audit-nsg-rdp-internet"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "NeoBanco: auditar NSG que permiten RDP desde internet"
  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Network/networkSecurityGroups" },
        {
          count = {
            field = "Microsoft.Network/networkSecurityGroups/securityRules[*]"
            where = {
              allOf = [
                { field = "Microsoft.Network/networkSecurityGroups/securityRules[*].access", equals = "Allow" },
                { field = "Microsoft.Network/networkSecurityGroups/securityRules[*].direction", equals = "Inbound" },
                { field = "Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRange", in = ["3389", "*"] },
                { field = "Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefix", in = ["*", "Internet", "0.0.0.0/0"] }
              ]
            }
          }
          greater = 0
        }
      ]
    }
    then = { effect = "audit" }
  })
}

resource "azurerm_resource_group_policy_assignment" "storage_publico" {
  name                 = "audit-storage-publico"
  resource_group_id    = azurerm_resource_group.neobanco["core"].id
  policy_definition_id = azurerm_policy_definition.storage_publico.id
}

resource "azurerm_resource_group_policy_assignment" "nsg_rdp" {
  name                 = "audit-nsg-rdp-internet"
  resource_group_id    = azurerm_resource_group.neobanco["core"].id
  policy_definition_id = azurerm_policy_definition.nsg_rdp_internet.id
}
