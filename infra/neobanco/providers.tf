terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.30" }
  }
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  # Las identidades del pipeline no pueden registrar resource providers (lo hizo bootstrap)
  resource_provider_registrations = "none"
  storage_use_azuread             = true
}
