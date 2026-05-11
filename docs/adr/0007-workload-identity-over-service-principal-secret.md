# ADR-0007: Use Workload Identity Federation Instead of Service Principal Client Secrets for AKS Workload Authentication

## Status

**Accepted**

---

## Context

Every workload in the AI platform that interacts with an Azure resource — ACR pull, Key Vault reads, Azure AI Foundry endpoints, Storage account access — requires an authentication identity. The traditional mechanism is a Service Principal with a client secret: register an app in Entra ID, generate a secret, store it somewhere the workload can read it, present it at token issuance time.

This programme's AI platform runs on AKS (locally simulated on k3d). The workloads that need Azure credentials include:

- The GitOps engine (Flux) pulling from ACR
- The RAG ingestion pipeline (Week 5) writing to storage and calling embedding endpoints
- The inference gateway (Week 4) calling Azure AI Foundry endpoints
- CI/CD pipelines (GitHub Actions) deploying to the AKS cluster and pushing to ACR

The authentication question is not hypothetical — it surfaces at Week 2 (identity model definition), Week 4 (model serving), and Week 5 (RAG pipeline), and becomes compounded in Week 9 (multi-tenant SaaS) where each tenant's workload isolation requires a distinct identity boundary.

### Constraints

- AKS Free tier, Australia East. Managed Identity is free; Service Principals are free; OIDC issuer is included in AKS at no additional cost.
- Multi-tenant pattern (Week 9) means identity decisions made now propagate to per-tenant isolation architecture later.
- GitHub Actions is a first-class CI/CD surface. The same identity decision applies there.
- k3d local environment does not have a publicly addressable OIDC issuer by default. Workload Identity federation requires AKS (or a cluster with an externally reachable OIDC discovery endpoint) for the Azure validation path.
- No existing secret management infrastructure (Key Vault with rotation policies) is deployed as part of this programme. Any secret-based approach starts from scratch.

### Drivers

| Driver | Description |
|--------|-------------|
| **Security** | Zero-Trust posture: credentials should not exist as exfiltrable strings at rest or in transit. Least-privilege by workload identity, not shared principal. |
| **Operational** | Rotation burden on secrets must be explicitly owned. If rotation fails or is missed, the consequence must be understood before the architecture is committed. |
| **Auditability** | Azure audit logs must be attributable to a workload (namespace + SA), not just to a shared principal. This is a compliance requirement in any regulated environment. |
| **Scalability** | The identity model must not degrade under multi-tenancy. An approach that works for 3 workloads must still work for 30 tenant-scoped workloads without linear operational overhead. |
| **Portability** | GitHub Actions (external CI) and AKS (in-cluster) workloads should use the same identity mechanism where possible. |

---

## Decision

**We will use Azure Workload Identity Federation (OIDC) with User-Assigned Managed Identities (UAMI) for all AKS workload authentication to Azure resources, and for GitHub Actions CI/CD pipelines.**

Each logical workload (Flux, RAG pipeline, inference gateway, per-tenant isolation boundary) gets its own UAMI. Each UAMI has exactly one federated credential binding it to a specific Kubernetes Service Account (or GitHub Actions workflow reference). No client secrets are created. No passwords are stored.

### Rationale

The decision rests on three architectural properties that service principal secrets cannot provide simultaneously: **bounded blast radius**, **zero rotation burden**, and **workload-attributable audit trails**.

#### Rotation Burden

A client secret has a maximum lifetime of 2 years in Entra ID (as of 2024). That is a policy ceiling, not a recommendation. In practice, most teams set 6–12 month expiry and rely on either manual rotation (which fails when the person who set it up has left) or automated rotation (which requires Key Vault, a rotation function, a secret sync mechanism back into Kubernetes, and monitoring for sync failures). Each additional service principal multiplies this operational surface.

Workload Identity has no secret to rotate. The federated credential is a trust configuration — an Entra object that says "tokens issued by this OIDC issuer, for this subject claim, are trusted to act as this identity." The credential cannot be extracted or leaked because it is not a secret; it is an assertion that a particular issuer's tokens are valid. The short-lived projected service account token that Kubernetes injects into the pod (mounted at `/var/run/secrets/azure/tokens/azure-identity-token`, default TTL 1 hour, non-renewable without re-issuance) is the only credential material in the system, and it is worthless outside its issuance context.

Rotation burden drops to zero for the credential itself. The federated credential configuration still needs lifecycle management (if a cluster is decommissioned, its issuer URL should be removed from the federated credential), but this is a configuration audit, not a secret rotation cadence.

#### Blast Radius

This is the property that most discussions underweight. A client secret, once issued, is **location-independent**. It will authenticate from a developer laptop, from an attacker's machine, from a cloud shell, from any IP, at any time, until it expires or is explicitly revoked. If the secret is in a CI log, in a Kubernetes Secret (base64 is not encryption), in a `.env` file that got committed, or in a memory dump — the blast radius is every Azure resource the service principal has access to, from anywhere on the internet, for the remaining life of the secret.

The blast radius of a Workload Identity token is structurally bounded by three constraints that are enforced by Entra at token exchange time:

1. **Issuer binding**: the projected token must be signed by the specific OIDC issuer registered in the federated credential. Only that cluster's API server can issue valid tokens.
2. **Subject binding**: the subject claim of the projected token must exactly match the federated credential's subject — `system:serviceaccount:<namespace>:<service-account-name>`. A token issued to `rag-pipeline/sa` cannot be used to act as `inference-gateway/sa`.
3. **Audience binding**: the token audience must match `api://AzureADTokenExchange`.

Even if an attacker extracts the projected JWT from a running pod, they cannot replay it from outside the cluster — it will fail the issuer check because the signing keys are not portable. They cannot use it from a different pod — the subject claim is pod-SA-scoped. And it expires in 1 hour maximum with no renewal path outside the cluster.

Concretely: for a 10-workload AI platform, service principal secrets create 10 location-independent, long-lived credentials. Workload Identity creates 10 cluster-bound, short-lived token exchanges. The aggregate attack surface reduction is substantial.

#### Auditability

Entra Sign-in logs record every token issuance. With a service principal, the log entry shows the SP's application ID. If three workloads share a SP (common cost-reduction pattern), or if a developer uses the same SP client credentials locally for testing, those events are indistinguishable in the audit log. You know *something* authenticated as `ai-platform-sp`; you do not know which pod in which namespace triggered it.

With Workload Identity, the federated credential subject is a structured string: `system:serviceaccount:rag-pipeline:ingestion-sa`. The Entra sign-in log includes the incoming federated token claims, which preserves this subject. Combined with the Kubernetes audit log (which records which controller or pod mounted the projected token), you have a traceable chain:

```
Pod rag-ingestion-7f9d4b-xxx in ns rag-pipeline
  → Projected token issued for SA ingestion-sa
  → Token exchanged at Entra (subject: system:serviceaccount:rag-pipeline:ingestion-sa)
  → Access token issued for UAMI ai-platform-rag-identity
  → Azure Storage write event attributed to ai-platform-rag-identity
```

That is the audit chain a security team can actually work with. In a regulated environment (financial services, healthcare), this chain is the difference between passing and failing an access review.

#### GitHub Actions Parity

GitHub Actions supports OIDC federation natively. A workflow file can request a GitHub-issued OIDC token, and a federated credential can be configured on the UAMI to trust tokens from `https://token.actions.githubusercontent.com` with subject `repo:InfraFactory/ai-platform:environment:production`. The same identity mechanism that authenticates in-cluster workloads authenticates the CI pipeline — no secrets stored in GitHub Actions secrets, no `AZURE_CLIENT_SECRET` env var in the workflow.

This parity matters architecturally: the identity model for "code running in CI" and "code running in-cluster" is unified. A secret-based CI pipeline creates a second credential surface that must be managed separately and often with less discipline than in-cluster credentials.

---

## Consequences

### Positive

- No client secrets created for any workload or CI pipeline. Secret sprawl is eliminated at the design level, not mitigated at the tooling level.
- Blast radius of any individual workload compromise is bounded to that SA's Azure RBAC grants, from that cluster only.
- Audit logs are workload-attributable without log correlation gymnastics.
- Multi-tenant isolation (Week 9) maps cleanly: one UAMI per tenant scope, one federated credential per tenant's SA. Tenant credential separation is enforced by the federated credential subject constraint, not by policy alone.
- GitHub Actions federation means zero secrets in the CI/CD configuration surface.

### Negative / Trade-offs

- **Local k3d simulation is partial.** k3d does not expose a publicly addressable OIDC discovery endpoint. The Workload Identity webhook can be installed locally (it's a Helm chart), and the SA annotation pattern can be exercised, but the actual federated token exchange to Azure cannot be completed from k3d without exposing the OIDC issuer (e.g. via ngrok or a similar tunnel). The full round-trip requires AKS.
- **Setup is more involved than a secret.** Creating a UAMI, enabling OIDC issuer and Workload Identity on the cluster, installing the webhook, creating the federated credential, annotating the SA — that is five steps before a workload can authenticate. A client secret is two steps (create SP, paste secret). The operational complexity of setup is higher; the operational complexity of day-2 maintenance is lower.
- **Federated credential lifecycle is a new operational surface.** When a cluster is decommissioned or its OIDC issuer URL changes (e.g. cluster recreation), existing federated credentials become orphaned and must be cleaned up. This is lower risk than a leaked secret but it is not zero maintenance.
- **Does not cover every authentication scenario.** Services that do not support OIDC audience constraints or Managed Identity as an authentication mechanism (some third-party SaaS APIs, some legacy on-prem systems) still require a credential. Workload Identity does not eliminate all secrets from an enterprise environment — it eliminates Azure-bound secrets.

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| OIDC issuer URL changes on cluster recreate, orphaning federated credentials | Medium | Low | Tag federated credentials with cluster name; include in cluster decommission runbook |
| Webhook misconfiguration prevents SA token projection; workloads fail to authenticate | Low | High | Test with `azure-identity` SDK debug logging before deploying to production workloads; include in cluster smoke test |
| Developer bypasses Workload Identity and creates SP + secret for "quick test" | Medium | Medium | Azure Policy: deny `microsoft.authorization/roleassignments` for application objects (SP) where service principal type is not `ManagedIdentity`. OPA policy in-cluster to alert on non-annotated SAs touching external Azure SDKs. |
| k3d local testing diverges from AKS behaviour (partial simulation) | High | Low | Document the simulation boundary explicitly. AKS validation is the authoritative test path for identity. |
| Multi-tenant UAMI proliferation becomes unmanageable at scale | Low (within programme scope) | Medium | Use a naming convention (`{platform}-{tenant-id}-{workload}`) and resource tagging from Week 9 onwards. Azure Policy: require tags on Managed Identity resources. |

---

## Alternatives Considered

### Option A: Service Principal + Client Secret in Kubernetes Secret

**Description:** Create a Service Principal in Entra ID, generate a client secret, store it as a `kubernetes.io/opaque` Secret in the relevant namespace, mount it as an environment variable via `envFrom` or `secretKeyRef`.

**Rejected because:** This is the naive form of the pattern and inherits all its failure modes without any mitigation. Kubernetes Secrets are base64-encoded (not encrypted) in etcd unless encryption at rest is explicitly configured. A `kubectl get secret -o yaml` in the right namespace exposes the credential in plaintext. Rotation requires manual intervention or additional tooling. Blast radius is unbounded — the secret is valid from any location. Audit attribution is SP-level, not workload-level. This option was not seriously evaluated as an acceptable steady-state; it was used as the baseline against which mitigations in other options are measured.

---

### Option B: Service Principal + Client Secret with External Secrets Operator + Azure Key Vault

**Description:** Store the client secret in Azure Key Vault with a rotation policy. Use External Secrets Operator (ESO) to sync the current secret value into a Kubernetes Secret on a defined schedule. Workloads consume the Kubernetes Secret as in Option A, but the rotation is automated by Key Vault's rotation function.

**Rejected because:** This is the most mature mitigation for service principal secrets and is genuinely common in enterprise environments. The rotation problem is substantially solved — Key Vault can rotate secrets automatically (though it requires a rotation function for arbitrary secrets, not just Key Vault-native certificate rotation). However, two of the three fundamental problems remain.

The blast radius problem is not solved. The secret exists as a string value in Key Vault, in ESO's in-memory state, and in the Kubernetes Secret at all times. It can be exfiltrated from any of those three locations. The RBAC on Key Vault access is a mitigation for the "who can read the secret" question but not for "what can an attacker do with the secret once read."

The auditability problem is not solved. The Entra sign-in log still shows the SP, not the workload. ESO introduces a new audit concern: which ESO sync event caused which secret version to be active.

ESO adds operational complexity (an additional controller, sync failure modes, sync interval tuning) without eliminating the underlying credential. It moves the problem; it does not remove it. This option makes sense in environments that cannot use Workload Identity (on-prem clusters, air-gapped environments, clusters without a publicly addressable OIDC issuer) — it is the best available mitigation when federation is not possible. In AKS, it is a workaround for a problem that doesn't need to exist.

---

### Option C: Service Principal + Certificate (x.509)

**Description:** Authenticate the Service Principal using a certificate rather than a client secret. The private key is stored in Azure Key Vault or as a Kubernetes Secret; the certificate is presented at token issuance time.

**Rejected because:** x.509 certificates are harder to accidentally leak than a cleartext string — they require private key extraction, which is a separate step. Certificates can be configured with shorter lifetimes (30–90 days is viable; 24-hour certificates are possible but operationally expensive). This is meaningfully better than a client secret on the rotation and blast radius dimensions.

However, it introduces PKI complexity that is not otherwise present in the programme stack. Key generation, certificate issuance, private key storage, and rotation (which, unlike secret rotation, also requires updating the certificate on the SP) all require infrastructure that Workload Identity eliminates entirely. The auditability problem remains identical to Option A and B — the Entra log shows the SP, not the workload.

This option is appropriate when Workload Identity is unavailable and the threat model requires stronger credential hygiene than a static secret. It is not appropriate as a first choice when Workload Identity is available.

---

### Option D: AAD Pod Identity v1 (Deprecated)

**Description:** The predecessor to Workload Identity on AKS. Used a node-level Managed Identity combined with a MIC (Managed Identity Controller) and NMI (Node Managed Identity) daemonset. Pods were assigned identities via `AzureIdentity` and `AzureIdentityBinding` CRDs.

**Rejected because:** Deprecated by Microsoft. The NMI daemonset operated at the node level and intercepted IMDS calls, which created a lateral movement risk — a container that could reach the NMI socket on the node could potentially impersonate another pod's identity. Workload Identity's token projection mechanism is pod-level and does not rely on IMDS interception. The successor (Workload Identity) is the recommended path for all new deployments and for migration from Pod Identity.

---

## Implementation Notes

### AKS Cluster Requirements

```bash
# Enable OIDC issuer and Workload Identity on AKS cluster
az aks update \
  --resource-group <rg> \
  --name <cluster> \
  --enable-oidc-issuer \
  --enable-workload-identity

# Retrieve OIDC issuer URL (needed for federated credential)
OIDC_ISSUER=$(az aks show \
  --resource-group <rg> \
  --name <cluster> \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)
```

### Identity Creation and Federation

```bash
# Create a User-Assigned Managed Identity per logical workload
az identity create \
  --name ai-platform-rag-identity \
  --resource-group <rg> \
  --location australiaeast \
  --tags programme=ai-accelerator week=2 workload=rag-pipeline

# Retrieve the client ID (used to annotate the Kubernetes SA)
UAMI_CLIENT_ID=$(az identity show \
  --name ai-platform-rag-identity \
  --resource-group <rg> \
  --query clientId -o tsv)

# Create the federated credential — binds the UAMI to a specific SA
az identity federated-credential create \
  --name rag-pipeline-k8s-federation \
  --identity-name ai-platform-rag-identity \
  --resource-group <rg> \
  --issuer "${OIDC_ISSUER}" \
  --subject "system:serviceaccount:rag-pipeline:ingestion-sa" \
  --audiences "api://AzureADTokenExchange"
```

### Kubernetes Service Account

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ingestion-sa
  namespace: rag-pipeline
  annotations:
    azure.workload.identity/client-id: "<UAMI_CLIENT_ID>"
    azure.workload.identity/tenant-id: "<TENANT_ID>"
```

### Pod Configuration

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rag-ingestion
  namespace: rag-pipeline
spec:
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"  # Triggers webhook token projection
    spec:
      serviceAccountName: ingestion-sa
      containers:
        - name: ingestion
          image: <acr>.azurecr.io/rag-ingestion:latest
          # Webhook injects:
          # AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE
          # azure-identity SDK picks these up automatically
```

### GitHub Actions Federation

```bash
# Federated credential for GitHub Actions CI pipeline
az identity federated-credential create \
  --name github-actions-production \
  --identity-name ai-platform-ci-identity \
  --resource-group <rg> \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:InfraFactory/ai-platform:environment:production" \
  --audiences "api://AzureADTokenExchange"
```

```yaml
# .github/workflows/deploy.yml (relevant permissions and auth step)
permissions:
  id-token: write   # Required for OIDC token request
  contents: read

steps:
  - name: Azure Login (OIDC, no secrets)
    uses: azure/login@v2
    with:
      client-id: ${{ vars.AZURE_CLIENT_ID }}      # UAMI client ID, not a secret
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

### Terraform Module (plan-validated, consistent with Week 2 deliverable)

```hcl
# modules/workload-identity/main.tf

resource "azurerm_user_assigned_identity" "workload" {
  name                = "${var.platform_name}-${var.workload_name}-identity"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(var.tags, {
    workload = var.workload_name
    week     = "2"
  })
}

resource "azurerm_federated_identity_credential" "k8s" {
  name                = "${var.workload_name}-k8s-federation"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.workload.id

  issuer   = var.oidc_issuer_url
  subject  = "system:serviceaccount:${var.k8s_namespace}:${var.k8s_service_account}"
  audience = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "workload_rbac" {
  for_each = var.role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

output "client_id" {
  description = "Client ID to annotate the Kubernetes Service Account"
  value       = azurerm_user_assigned_identity.workload.client_id
}

output "principal_id" {
  description = "Principal ID for RBAC assignments"
  value       = azurerm_user_assigned_identity.workload.principal_id
}
```

### k3d Local Simulation Boundary

The Workload Identity webhook (`azure-workload-identity-webhook`) can be installed into k3d via Helm and will inject the relevant environment variables. The SA annotation and pod label patterns can be exercised locally. The federated token exchange to Entra **cannot** be completed from k3d without exposing the cluster's OIDC issuer at a publicly reachable URL — the federation spec requires Entra to fetch the JWKS from the cluster's OIDC discovery endpoint to validate the projected token.

Workaround for local validation: use `ngrok` or a similar tunnel to expose the k3d OIDC endpoint, then register that ephemeral URL as the issuer in a test federated credential. This is documented in the Microsoft Workload Identity maintainer docs. For programme purposes, AKS is the authoritative test path; k3d validates the configuration pattern only.

### Prerequisites

- [ ] AKS cluster with `--enable-oidc-issuer` and `--enable-workload-identity` (or `az aks update` on existing cluster)
- [ ] Workload Identity webhook Helm chart installed: `azure-workload-identity/workload-identity-webhook`
- [ ] UAMI created per workload (not shared across workloads)
- [ ] Federated credential created with correct issuer URL (post-cluster creation — OIDC URL is stable but should not be assumed constant across cluster recreates)
- [ ] Kubernetes SA annotated with `azure.workload.identity/client-id`
- [ ] Pod or Deployment labelled with `azure.workload.identity/use: "true"`
- [ ] `azure-identity` SDK (Python: `azure-identity`, .NET: `Azure.Identity`) used in workload code — `DefaultAzureCredential` picks up the injected env vars automatically

### Rollback Plan

Workload Identity can be disabled per-workload by removing the SA annotation and pod label. The UAMI and federated credential remain in Azure and can be re-associated. If a workload must fall back to a service principal (e.g. the cluster's OIDC issuer is temporarily unavailable during a cluster recreate), a SP + secret can be created and the Kubernetes Secret mounted in parallel — Workload Identity and SP auth are not mutually exclusive at the workload level. The intent is to avoid this state; the escape hatch exists.

---

## Conditions for Revisiting This Decision

This decision should be revisited if:

1. **The programme expands to on-premises or air-gapped Kubernetes**, where no publicly addressable OIDC issuer can be established. In this scenario, Option B (ESO + Key Vault) becomes the appropriate fallback.
2. **A workload needs to authenticate to a non-Azure service** that does not support OIDC federation (e.g., a third-party SaaS API, a private certificate authority). That specific credential still requires a secret; this ADR applies only to Azure-bound authentication.
3. **The Azure Workload Identity webhook is deprecated or superseded** by a built-in AKS mechanism. Monitor `azure-workload-identity` GitHub releases and AKS release notes.
4. **A multi-cloud identity plane is introduced** (e.g., SPIFFE/SPIRE for workload identity across AKS + GKE). This would replace the Azure-specific federation mechanism with a universal identity fabric; the architectural intent of this ADR (no secrets, bounded blast radius, workload attribution) would carry forward.

---

## Review

| Field | Value |
|-------|-------|
| **Date** | 2025-05-01 |
| **Author(s)** | Israel O. |
| **Reviewed by** | — |
| **Project phase / Week** | Phase 1 / Week 2 — Governance, Identity & Zero-Trust |
| **Next review date** | 2025-08-01 (or when AKS validation stage begins) |

---

## References

- [Microsoft Docs: Azure Workload Identity with AKS](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Azure Workload Identity OSS project](https://azure.github.io/azure-workload-identity/)
- [OIDC Federation trust model — RFC 7519 (JWT) + OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html)
- [GitHub Actions OIDC federation with Azure](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure)
- [Entra ID Federated Identity Credentials concept](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [External Secrets Operator](https://external-secrets.io/) — referenced in Alternative B
- [ADR-0001: Hub-Spoke vs vWAN](./0001-hub-spoke-vs-vwan.md)
- [ADR-0002: Kubernetes Version Pin](./0002-kubernetes-version-pin.md)
- [ADR-0003: Observability Stack Selection](./0003-kube-prometheus-stack-version-pin.md)
