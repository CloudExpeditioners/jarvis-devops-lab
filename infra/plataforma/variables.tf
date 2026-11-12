variable "subscription_id" {
  type = string
}

variable "ubicacion" {
  type    = string
  default = "spaincentral"
}

variable "ubicacion_funciones" {
  description = "Región de la Function (Flex Consumption). Si spaincentral no la soporta, usa swedencentral o northeurope."
  type        = string
  default     = "spaincentral"
}

variable "tfstate_sa_id" {
  description = "ID del storage de bootstrap (TFSTATE_SA_ID en salida-bootstrap.json)"
  type        = string
}

variable "plan_principal_id" {
  type = string
}

variable "apply_principal_id" {
  type = string
}

variable "mi_usuario_object_id" {
  type = string
}

variable "github_owner" {
  type = string
}

variable "github_repo" {
  type    = string
  default = "jarvis-devops"
}

variable "github_app_id" {
  type = string
}

variable "github_app_installation_id" {
  type = string
}

variable "max_targets" {
  type    = number
  default = 5
}

variable "presupuesto_usd" {
  type    = number
  default = 100
}

variable "email_alertas" {
  type = string
}

variable "presupuesto_inicio" {
  description = "Primer día del mes en curso, formato RFC3339"
  type        = string
  default     = "2026-11-01T00:00:00Z"
}
