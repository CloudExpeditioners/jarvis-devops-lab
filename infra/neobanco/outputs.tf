output "nsg_app"              { value = azurerm_network_security_group.app.name }
output "storage_transacciones" { value = azurerm_storage_account.transacciones.name }
output "app_service_plan"     { value = azurerm_service_plan.core.name }
output "web_app"              { value = azurerm_linux_web_app.core.name }
