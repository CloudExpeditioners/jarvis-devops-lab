variable "ubicacion" {
  type    = string
  default = "spaincentral"
}

variable "sufijo" {
  description = "Sufijo único (salida 'sufijo' de infra/plataforma)"
  type        = string
}

variable "app_service_sku" {
  description = "SKU del plan de App Service del core bancario. JARVIS puede proponer cambios SOLO a esta variable."
  type        = string
  validation {
    condition     = can(regex("^(B[1-3]|P[0-3]v3)$", var.app_service_sku))
    error_message = "SKU no permitido. Valores válidos: B1-B3, P0v3-P3v3."
  }
}

variable "sql_admin_login" {
  description = "Nombre visible del administrador Entra ID del servidor SQL"
  type        = string
}

variable "sql_admin_object_id" {
  description = "Object ID (usuario o grupo de Entra ID) administrador del SQL. Sin contraseñas."
  type        = string
}

variable "log_analytics_id" {
  description = "ID del Log Analytics de plataforma (salida 'log_analytics_id' de infra/plataforma). Se pasa como ID para que la identidad de plan no necesite leer las claves del workspace."
  type        = string
}
