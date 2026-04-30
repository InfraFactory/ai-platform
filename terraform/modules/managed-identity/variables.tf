variable "name" {
  description = "Name of the User-Assigned Managed Identity. Convention: id-<scope>-<role>"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy the identity into"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "role_assignments" {
  description = "List of Azure role assignments for this identity"
  type = list(object({
    role_definition_name = string
    scope                = string
    description          = optional(string, "")
  }))
  default = []
}

variable "federated_credentials" {
  description = "Workload Identity federation config. One entry per Kubernetes ServiceAccount."
  type = list(object({
    name                = string        # unique name for the federated credential
    namespace           = string        # Kubernetes namespace
    service_account_name = string       # Kubernetes ServiceAccount name
    aks_oidc_issuer_url = string        # from azurerm_kubernetes_cluster.oidc_issuer_url
  }))
  default = []
}
