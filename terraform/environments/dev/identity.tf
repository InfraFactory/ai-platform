# ── P1: Platform Engineer identity ───────────────────────────────────────────
# Used by Terraform pipelines and local operator sessions.
# Contributor + User Access Administrator scoped to the resource group —
# the UA allows Terraform to assign roles to other identities without
# subscription-level IAM rights.

module "id_platform_operator" {
  source = "../../modules/managed-identity"

  name                = "id-platform-operator"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  role_assignments = [
    {
      role_definition_name = "Contributor"
      scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
      description          = "Terraform requires create/update/delete on platform resources"
    },
    {
      role_definition_name = "User Access Administrator"
      scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
      description          = "Allows Terraform to assign roles to other identities within this RG only"
    }
  ]
}

# ── P2: AKS kubelet identity ──────────────────────────────────────────────────
# Assigned to the AKS node pool. Pulls images from ACR and reads secrets
# from Key Vault via the CSI driver. Scoped to specific resources, not the RG.

module "id_aks_kubelet" {
  source = "../../modules/managed-identity"

  name                = "id-aks-kubelet"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  role_assignments = [
    {
      role_definition_name = "AcrPull"
      scope                = var.acr_id
      description          = "Node pool pulls images from ACR — scoped to the single registry, not the RG"
    },
    {
      role_definition_name = "Key Vault Secrets User"
      scope                = var.key_vault_id
      description          = "CSI driver reads secrets from Key Vault — no write access"
    }
  ]
}

# ── P5: AI workload identity ──────────────────────────────────────────────────
# Federated to the ai-workloads/sa-ai-workload Kubernetes ServiceAccount.
# Pods annotated with this SA can exchange their projected service account
# token for an Azure AD access token via Workload Identity OIDC.

module "id_ai_workload" {
  source = "../../modules/managed-identity"

  name                = "id-ai-workload"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  role_assignments = [
    {
      role_definition_name = "Key Vault Secrets User"
      scope                = var.key_vault_id
      description          = "AI workload reads model config and API keys — no write access"
    }
    # Cognitive Services User assignment added at Week 9 when Azure AI Foundry is provisioned
  ]

  federated_credentials = [
    {
      name                 = "fc-ai-workloads-sa-ai-workload"
      namespace            = "ai-workloads"
      service_account_name = "sa-ai-workload"
      aks_oidc_issuer_url  = var.aks_oidc_issuer_url
    }
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
# Consumed by downstream modules (AKS, ACR, Key Vault) via module references.
# Changes to identity names propagate through the graph — no manual ID hunting.

output "platform_operator_client_id" {
  value = module.id_platform_operator.client_id
}

output "aks_kubelet_client_id" {
  value = module.id_aks_kubelet.client_id
}

output "aks_kubelet_principal_id" {
  value       = module.id_aks_kubelet.principal_id
  description = "Required by AKS module to attach the kubelet identity to the node pool"
}

output "ai_workload_client_id" {
  value       = module.id_ai_workload.client_id
  description = "Annotate the Kubernetes ServiceAccount with this value"
}
