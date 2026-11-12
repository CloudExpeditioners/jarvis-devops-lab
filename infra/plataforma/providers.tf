terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.30" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # Valores en backend.hcl (ver GUIA paso 3). Estado en el storage creado por bootstrap.
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}
