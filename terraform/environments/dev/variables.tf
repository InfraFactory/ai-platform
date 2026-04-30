variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for dev platform resources"
  type        = string
  default     = "rg-cloudville-platform-dev"
}

variable "location" {
  description = "Primary Azure region"
  type        = string
  default     = "australiaeast"
}

variable "aks_oidc_issuer_url" {
  description = <<-EOT
    OIDC issuer URL from the AKS cluster.
    Retrieve after AKS is deployed: az aks show \
      --name <cluster> --resource-group <rg> \
      --query oidcIssuerProfile.issuerUrl -o tsv
  EOT
  type    = string
  default = "" # populated when AKS is deployed in Week 3
}

variable "acr_id" {
  description = "Resource ID of the Azure Container Registry"
  type        = string
  default     = "" # populated when ACR is deployed
}

variable "key_vault_id" {
  description = "Resource ID of the Azure Key Vault"
  type        = string
  default     = "" # populated when Key Vault is deployed
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    environment = "dev"
    managed-by  = "terraform"
    programme   = "ai-systems-architect-accelerator"
    week        = "2"
  }
}
