output "sufijo"               { value = random_string.sufijo.result }
output "servicebus_fqdn"      { value = "${azurerm_servicebus_namespace.sb.name}.servicebus.windows.net" }
output "function_app_name"    { value = azurerm_function_app_flex_consumption.jarvis.name }
output "function_hostname"    { value = azurerm_function_app_flex_consumption.jarvis.default_hostname }
output "mcp_url"              { value = "https://${azurerm_function_app_flex_consumption.jarvis.default_hostname}/api/mcp" }
output "key_vault_jarvis"     { value = azurerm_key_vault.jarvis.name }
output "log_analytics_id"     { value = azurerm_log_analytics_workspace.law.id }

output "copilot_servicebus_connection_string" {
  description = "Conexión de SOLO ESCUCHA a la cola jarvis-drift, para el disparador de Copilot Studio"
  value       = azurerm_servicebus_queue_authorization_rule.copilot_listen.primary_connection_string
  sensitive   = true
}
