terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Backend config left as local for Week 2 — migrate to Azure Storage in Week 3
  # when the ALZ storage account is available
  backend "local" {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
