terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

resource "azurerm_user_assigned_identity" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "this" {
  for_each = {
    for fc in var.federated_credentials : fc.name => fc
  }

  name      = each.value.name
  parent_id = azurerm_user_assigned_identity.this.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = each.value.aks_oidc_issuer_url
  subject  = "system:serviceaccount:${each.value.namespace}:${each.value.service_account_name}"
}
