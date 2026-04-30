# RBAC Model — Cloudville AI Platform

**Version:** 1.0  
**Date:** 2026-04-30  
**Author:** Israel  
**Phase:** Phase 1 · Week 2 — Governance, Identity & Zero-Trust Security  
**Status:** Active — personas 2–4 partially implemented; full enforcement target: Week 5

---

## Overview

This document defines the identity and access model for the Cloudville AI Platform
across two planes: Kubernetes RBAC and Azure RBAC. The two planes are not independent.
A CI service account that has `push` rights on ACR but no `imagePullSecrets` binding
in the model namespace can build an image it can never deploy. A tenant application
that can write to its namespace but has no Workload Identity binding cannot reach
Azure Key Vault. The design decisions in each section must be read with the other in
mind.

The model is designed for the multi-tenant SaaS architecture targeted in Weeks 5–10.
Not all personas are active today — the platform is currently operated by a single
engineer. However, modelling the full persona set now prevents structural refactoring
later when tenant namespaces, CI pipelines, and read-only stakeholder access arrive.

### Design Principles

**Least privilege by default.** No persona receives more access than the narrowest
scope required for its function. Escalation paths are explicit and documented, not
implicit in role inheritance.

**Namespace as trust boundary.** In the Kubernetes plane, the namespace is the primary
isolation unit. Cross-namespace access is a deliberate exception, not a convenience.
OPA Gatekeeper enforces this at admission time — the RBAC model defines intent;
Gatekeeper provides the enforcement backstop.

**Identity follows workload, not operator.** Service accounts are workload-specific,
not shared across applications. A compromised service account should yield the minimum
blast radius: access to one workload's resources, not the platform.

**Azure and Kubernetes identity are bridged, not duplicated.** Workloads that need
Azure resource access use Workload Identity (OIDC federation between AKS and Azure AD)
rather than long-lived credentials. The Kubernetes service account is the identity
primitive; the Azure Managed Identity is the Azure-side projection of that identity.

---

## Personas

| ID | Persona | Description | Currently active |
|----|---------|-------------|-----------------|
| P1 | Platform Engineer | Owns cluster infrastructure, Flux, Gatekeeper, platform components | ✓ |
| P2 | Application Team | Deploys and operates workloads within an assigned namespace | Partial (Week 5) |
| P3 | Read-Only Observer | Audits cluster state — SRE on-call, security reviewer, stakeholder | Not yet |
| P4 | CI Service Account | Automated pipeline identity — builds images, applies manifests, runs evaluations | Not yet |
| P5 | AI Workload Identity | In-cluster pod identity for workloads requiring Azure resource access | Not yet |

---

## Part 1 — Kubernetes RBAC

### 1.1 ClusterRole Definitions

The platform defines four ClusterRoles. These are cluster-scoped definitions;
bindings constrain where they apply.

#### `platform-admin`

Full cluster access. Bound only to the Platform Engineer persona. Not a superset of
`cluster-admin` — `cluster-admin` is reserved for break-glass scenarios and is not
assigned to any regular operational identity.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-admin
  labels:
    app.kubernetes.io/managed-by: flux
rules:
  # Core resources
  - apiGroups: [""]
    resources: ["*"]
    verbs: ["*"]
  # Apps, batch, autoscaling
  - apiGroups: ["apps", "batch", "autoscaling"]
    resources: ["*"]
    verbs: ["*"]
  # Networking
  - apiGroups: ["networking.k8s.io", "gateway.networking.k8s.io"]
    resources: ["*"]
    verbs: ["*"]
  # Flux
  - apiGroups: ["kustomize.toolkit.fluxcd.io", "helm.toolkit.fluxcd.io",
               "source.toolkit.fluxcd.io", "notification.toolkit.fluxcd.io"]
    resources: ["*"]
    verbs: ["*"]
  # Gatekeeper
  - apiGroups: ["templates.gatekeeper.sh", "constraints.gatekeeper.sh",
               "config.gatekeeper.sh"]
    resources: ["*"]
    verbs: ["*"]
  # RBAC introspection (not escalation — no bind/escalate verbs)
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
    verbs: ["get", "list", "watch"]
```

Note the deliberate omission of `bind` and `escalate` verbs on RBAC resources. The
Platform Engineer can inspect the RBAC model but cannot grant themselves or others
higher privilege than they already hold without a `cluster-admin` break-glass.

---

#### `namespace-developer`

Scoped to application lifecycle within a namespace. Bound via RoleBinding, not
ClusterRoleBinding — the ClusterRole definition is reused across tenant namespaces
but each binding is namespace-scoped.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-developer
  labels:
    app.kubernetes.io/managed-by: flux
rules:
  # Workload resources
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/exec", "pods/portforward",
                "services", "configmaps", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Gateway API routes — app teams own HTTPRoutes, not Gateways
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes", "grpcroutes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Secrets — read only; creation is platform or ESO responsibility
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
  # Events — read only for debugging
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
```

App teams do not own `Gateway` resources — those live in `infrastructure/` and are
Flux-managed. They own `HTTPRoute` resources that reference a platform-managed
`Gateway`. This is the Gateway API role separation model: infrastructure operator
owns the gateway; application team owns the routes.

App teams cannot create or update `Secrets` directly. Secrets are provisioned by the
platform via External Secrets Operator (ESO) pulling from Azure Key Vault. This
prevents credential sprawl and ensures all secrets have an auditable Azure-side origin.

---

#### `cluster-observer`

Read-only access across all namespaces. Bound at ClusterRoleBinding scope for the
Read-Only Observer persona, so a single binding covers the entire cluster.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-observer
  labels:
    app.kubernetes.io/managed-by: flux
rules:
  - apiGroups: ["", "apps", "batch", "autoscaling"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io", "gateway.networking.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["kustomize.toolkit.fluxcd.io", "helm.toolkit.fluxcd.io",
               "source.toolkit.fluxcd.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["templates.gatekeeper.sh", "constraints.gatekeeper.sh"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
    verbs: ["get", "list", "watch"]
  # Explicitly excluded: exec, portforward, secret data
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]   # metadata only — data field requires explicit get on a named secret
```

The observer cannot exec into pods, port-forward, or trigger any mutation. The
`secrets` entry deliberately omits `watch` — watch streams secret data changes in
real time, which is a higher-privilege operation than a point-in-time `get`.

---

#### `ci-deployer`

Scoped to the operations a CI pipeline legitimately needs: applying manifests and
reading deployment state. Bound per-namespace via RoleBinding, not cluster-wide.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ci-deployer
  labels:
    app.kubernetes.io/managed-by: flux
rules:
  # Apply manifests
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  # Gateway API routes
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  # Rollout status
  - apiGroups: ["apps"]
    resources: ["deployments/status", "statefulsets/status"]
    verbs: ["get", "watch"]
  # Pod observation for rollout verification
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  # Explicitly excluded: delete, exec, portforward, secrets write, RBAC
```

`delete` is excluded deliberately — a CI pipeline that can delete production
deployments is a significant blast radius if a pipeline is compromised or
misconfigured. Rollbacks are handled by updating the manifest (patching the image
tag), not by deleting and recreating.

---

### 1.2 Binding Model

Bindings wire personas to roles at the appropriate scope. The table below defines
the binding strategy; actual RoleBinding manifests live in `infrastructure/rbac/`.

| Persona | Role | Binding type | Scope |
|---------|------|-------------|-------|
| P1 Platform Engineer | `platform-admin` | ClusterRoleBinding | Cluster-wide |
| P2 Application Team | `namespace-developer` | RoleBinding | Per tenant namespace |
| P3 Read-Only Observer | `cluster-observer` | ClusterRoleBinding | Cluster-wide |
| P4 CI Service Account | `ci-deployer` | RoleBinding | Per target namespace |
| P5 AI Workload Identity | Service account only | n/a | Per workload namespace |

P5 (AI Workload Identity) does not receive a Kubernetes RBAC role. Its identity
purpose is Azure resource access via Workload Identity, not Kubernetes API access.
It gets a dedicated ServiceAccount with Workload Identity annotations; Kubernetes
RBAC is not the relevant control plane for this persona.

---

### 1.3 Namespace Structure and Trust Boundaries

```
flux-system          ← Flux controllers. No external bindings. Gatekeeper-exempted.
gatekeeper-system    ← Gatekeeper. No external bindings. Gatekeeper-exempted.
monitoring           ← kube-prometheus-stack. Platform Engineer only. Gatekeeper-exempted.
kube-system          ← Kubernetes system. No external bindings. Gatekeeper-exempted.
kong                 ← Kong gateway. Platform Engineer only.
cert-manager         ← cert-manager. Platform Engineer only.
ai-workloads         ← Model workloads (Ollama, Qdrant). P2 + P4 + P5 per workload.
applications         ← App team workloads. P2 + P4 per tenant namespace (Week 5+).
```

Tenant namespaces (Week 5+) follow the pattern `tenant-<id>`. Each tenant gets
its own RoleBinding for `namespace-developer` and `ci-deployer`. Cross-tenant
namespace access is denied by Gatekeeper's `restrict-model-namespace` constraint
and future tenant isolation policies.

---

### 1.4 Service Account Conventions

| Convention | Rationale |
|-----------|-----------|
| One ServiceAccount per workload, not per namespace | Blast radius of a compromised SA is bounded to one workload |
| `automountServiceAccountToken: false` by default | Pods that don't need API server access should not have a token mounted |
| Workload Identity SAs annotated with Azure client ID | Explicit declaration of Azure-side identity projection |
| No shared `default` SA used for any workload | The `default` SA is a footgun — it mounts a token and has implicit permissions |

---

## Part 2 — Azure RBAC

### 2.1 Managed Identity Strategy

The platform uses User-Assigned Managed Identities (UAMI), not System-Assigned.
UAMIs are:

- Reusable across resources if the same identity needs access to multiple Azure services
- Independently lifecycle-managed — deleting an AKS cluster does not delete the identity
- Auditable as first-class Azure resources with their own IAM assignment history
- Federated to Kubernetes ServiceAccounts via Workload Identity OIDC

One UAMI per workload role. The platform currently defines three:

| Identity | Purpose | Federated to |
|----------|---------|-------------|
| `id-platform-operator` | Terraform deployments, AKS management | CI pipeline / local operator |
| `id-aks-kubelet` | AKS node pool kubelet — ACR pull, Key Vault CSI | AKS node pool system SA |
| `id-ai-workload` | AI workload pods — Key Vault secrets, Azure AI services | `ai-workloads/sa-ai-workload` |

Additional identities will be added at Week 5 (tenant isolation) and Week 9
(LLMOps pipeline). The naming convention `id-<scope>-<role>` is enforced in the
Terraform module to prevent identity sprawl.

---

### 2.2 Role Assignments

Assignments follow the principle of least privilege against the narrowest scope
available: resource-level where possible, resource-group-level only when the
workload genuinely needs access to multiple resources of the same type.

| Identity | Azure Role | Scope | Rationale |
|----------|-----------|-------|-----------|
| `id-platform-operator` | `Contributor` | Resource Group | Terraform requires create/update/delete on platform resources |
| `id-platform-operator` | `User Access Administrator` | Resource Group | Terraform assigns roles to other identities (scoped to RG, not subscription) |
| `id-aks-kubelet` | `AcrPull` | ACR resource | Node pool pulls images; scope is the single ACR, not the RG |
| `id-aks-kubelet` | `Key Vault Secrets User` | Key Vault resource | CSI driver reads secrets; no write access |
| `id-ai-workload` | `Key Vault Secrets User` | Key Vault resource | AI workload reads model config and API keys; no write access |
| `id-ai-workload` | `Cognitive Services User` | Azure AI resource | Week 9 — model inference via Azure AI Foundry |

`User Access Administrator` on `id-platform-operator` is scoped to the resource
group, not the subscription. This allows Terraform to assign roles to
`id-aks-kubelet` and `id-ai-workload` without requiring subscription-level IAM
rights. The scope constraint is what makes this defensible — subscription-level
`User Access Administrator` would be a significant over-grant.

---

### 2.3 Workload Identity Federation

Workload Identity replaces pod-mounted credentials (client secret JSON files,
`azure.json` mounted as a volume) with OIDC token exchange. The flow:

```
Pod requests Azure resource
  → Azure SDK reads projected service account token from /var/run/secrets/...
    → Token sent to Azure AD OIDC endpoint
      → Azure AD validates token against registered federation
        → Azure AD issues short-lived access token for the Managed Identity
          → Pod accesses Azure resource with that token
```

The federation is defined as a Federated Identity Credential on the UAMI:

```hcl
# terraform/modules/managed-identity/main.tf
resource "azurerm_federated_identity_credential" "workload" {
  name                = "fc-${var.namespace}-${var.service_account_name}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.this.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = var.aks_oidc_issuer_url      # from azurerm_kubernetes_cluster.oidc_issuer_url
  subject  = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
}
```

The `subject` field is the exact string the Kubernetes API server includes in the
projected token — `system:serviceaccount:<namespace>:<name>`. It must match exactly.
A service account renamed or moved to a different namespace silently breaks the
federation without an error at configuration time — the failure surfaces only when
the workload pod attempts a token exchange.

---

### 2.4 Terraform Module Structure

Identity resources live in `terraform/modules/managed-identity/`. The module is
called once per identity, keeping each identity's assignment history independently
auditable in `terraform plan` output.

```
terraform/
  modules/
    managed-identity/
      main.tf          ← UAMI + federated credential
      rbac.tf          ← azurerm_role_assignment resources
      variables.tf
      outputs.tf       ← identity client_id, principal_id for downstream modules
  environments/
    dev/
      identity.tf      ← module calls: one block per identity
```

The module outputs `client_id` and `principal_id`. Downstream modules (AKS, ACR,
Key Vault) consume these outputs rather than hardcoding identity references — a
change to the identity propagates through the graph via Terraform dependencies, not
manual updates.

---

### 2.5 Azure RBAC and Kubernetes RBAC: The Bridge

The two planes intersect at the AI workload layer. A correctly configured AI workload
identity requires all of the following to be true simultaneously:

```
Azure plane                              Kubernetes plane
─────────────────────────────────────────────────────────
UAMI exists                              ServiceAccount exists in correct namespace
Federated credential configured          ServiceAccount annotated with UAMI client ID
Role assignment on target resource       Pod spec references the ServiceAccount
AKS OIDC issuer URL correct in fed cred  Workload Identity webhook injects env vars
```

A failure in any one of these eight conditions produces an authentication error that
surfaces in the workload pod, not at the configuration point. The Terraform module
structure makes the Azure-side conditions a single `terraform apply` operation; the
Kubernetes-side conditions are validated by the Gatekeeper policies and the
`restrict-model-namespace` constraint ensures the ServiceAccount is in the expected
namespace before the workload can run.

---

## Gaps and Deferred Items

| Item | Target week | Notes |
|------|------------|-------|
| Tenant namespace RBAC (P2 RoleBindings per tenant) | Week 5 | Requires namespace vending — each new tenant namespace gets RoleBindings from the Scaffolder template |
| CI service account per pipeline (P4) | Week 6 | GitHub Actions OIDC federation to Azure + kubeconfig binding |
| Read-only observer binding (P3) | Week 8 | Grafana dashboard access and audit tooling arrive here |
| `id-ai-workload` Cognitive Services role assignment | Week 9 | Azure AI Foundry integration |
| Break-glass `cluster-admin` procedure | Week 10 | Document and test the escalation path; store kubeconfig in Azure Key Vault |

---

## References

- [ADR-0004 OPA Gatekeeper admission control](./adr/0004-opa-gatekeeper-admission-control.md)
- [ADR-0005 Platform ingress strategy](./adr/0005-platform-ingress-strategy.md)
- [Kubernetes RBAC documentation](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Azure Workload Identity for AKS](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Azure built-in roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles)
- [Federated Identity Credentials](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- `terraform/modules/managed-identity/`
- `infrastructure/rbac/`
