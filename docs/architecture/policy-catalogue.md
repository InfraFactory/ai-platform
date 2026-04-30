# Policy Catalogue — Cloudville AI Platform

**Version:** 1.0  
**Date:** 2026-04-30  
**Engine:** OPA Gatekeeper 3.22.2  
**Phase:** Phase 1 · Week 2 — Governance, Identity & Zero-Trust Security

---

## Overview

This document is the single reference for all OPA Gatekeeper policies active on the
Cloudville AI Platform cluster. For each policy it records: what is enforced and why,
current enforcement action, excluded namespaces, the condition for escalating to
`deny`, and the Azure Policy equivalent for AKS validation.

Policies live in two directories:

```
policies/
  templates/    ← ConstraintTemplates (Rego logic, one file per policy)
  constraints/  ← Constraints (enforcement config, one file per policy)
```

Both directories are Flux-managed. Templates are applied first via
`platform-policies-templates` Kustomization; Constraints follow via
`platform-policies-constraints` Kustomization with `dependsOn` ensuring CRDs exist
before Constraints are applied.

---

## Policy Index

| # | Name | Kind | Enforcement | Validates |
|---|------|------|-------------|-----------|
| P1 | [require-resource-limits](#p1--require-resource-limits) | `RequireResourceLimits` | `warn` | Pod |
| P2 | [deny-public-loadbalancer](#p2--deny-public-loadbalancer) | `DenyPublicLoadBalancer` | `deny` | Service |
| P3 | [restrict-model-namespace](#p3--restrict-model-namespace) | `RestrictModelNamespace` | `deny` | Pod |
| P4 | [require-sa-token-control](#p4--require-sa-token-control) | `RequireSATokenControl` | `warn` | Pod |

---

## P1 — require-resource-limits

**File:** `policies/templates/require-resource-limits.yaml` · `policies/constraints/require-resource-limits.yaml`

### What it enforces

Every container and init container in a Pod must declare explicit `resources.limits.cpu`
and `resources.limits.memory`. The absence of either limit produces a violation.

### Why

Without resource limits, a single misbehaving container (a runaway inference loop,
a memory leak in a RAG pipeline component) can exhaust node resources and cause
cascading pod evictions across the cluster. On a single-node k3d cluster this means
total cluster failure from one unconstrained workload. On AKS with multiple tenants,
it means one tenant's workload can starve another's.

Resource limits also enable the Kubernetes scheduler to make accurate bin-packing
decisions. A pod without limits is effectively declaring "I need everything" — the
scheduler cannot reason about placement correctly.

### Current enforcement action: `warn`

Existing platform components (kube-prometheus-stack, Flux controllers) may not declare
resource limits. A hard `deny` would block those workloads on restart. Warn first,
audit the violation list, remediate platform components, then escalate to `deny`.

### Escalate to `deny` when

All pods in non-excluded namespaces declare resource limits — confirmed via:

```bash
kubectl get requireresourcelimits require-resource-limits \
  -o jsonpath='{.status.violations}' | jq 'length'
# Output must be 0 before switching to deny
```

Target: Week 5, before tenant namespaces are created. A tenant workload with no limits
in a multi-tenant cluster is a higher risk than a single-operator cluster.

### Excluded namespaces

`kube-system` · `kube-public` · `kube-node-lease` · `gatekeeper-system` · `flux-system` · `monitoring`

### Azure Policy equivalent

Built-in policy: **"Kubernetes cluster containers CPU and memory resource limits should not exceed the specified limits"**  
Policy definition ID: `e345eecc-fa47-480f-9e88-67dcc122b164`

The Rego logic is functionally equivalent. The Azure Policy version adds a parameter
for maximum limit values; our Rego enforces presence only, not magnitude.

---

## P2 — deny-public-loadbalancer

**File:** `policies/templates/deny-public-loadbalancer.yaml` · `policies/constraints/deny-public-loadbalancer.yaml`

### What it enforces

Services of type `LoadBalancer` are denied in any namespace not explicitly listed in
`allowedNamespaces`. The current permitted list is `["kong"]`.

### Why

A `LoadBalancer` Service on AKS provisions an Azure Load Balancer with a public IP.
On k3d, it provisions a local load balancer via k3d's built-in implementation. In
both cases, an unrestricted `LoadBalancer` Service means any workload — including a
tenant's application or a misconfigured AI inference server — can expose itself
directly to the network without going through the platform's ingress and API gateway
layer.

The ingress and API gateway layer (Kong, Week 3) is where authentication, rate
limiting, tenant routing, and observability are enforced. A LoadBalancer that bypasses
it bypasses all of those controls.

### Current enforcement action: `deny`

This is safe to deny immediately. A Service of type `LoadBalancer` outside the
permitted namespace list is an unconditional misconfiguration — there is no legitimate
use case for a tenant workload exposing itself via a raw LoadBalancer endpoint on this
platform.

### Escalate to `deny` when

Already `deny`. No escalation required.

### Adding permitted namespaces

If Week 3 selects Traefik instead of Kong, update the constraint:

```yaml
# policies/constraints/deny-public-loadbalancer.yaml
spec:
  parameters:
    allowedNamespaces:
      - traefik   # replace kong if Week 3 ADR selects Traefik
```

### Excluded namespaces

None — the policy applies cluster-wide. The `allowedNamespaces` parameter controls
permitted namespaces rather than constraint-level exclusions.

### Azure Policy equivalent

Built-in policy: **"Kubernetes clusters should not allow endpoint edit permissions of ClusterRole/system:aggregate-to-edit"** — partial overlap only.  

For a precise equivalent, use a custom Azure Policy initiative with Rego:

```rego
package deny_public_loadbalancer
violation[{"msg": msg}] {
  input.review.object.spec.type == "LoadBalancer"
  not namespace_allowed(input.review.object.metadata.namespace)
  msg := "Service type LoadBalancer not permitted outside ingress namespaces"
}
```

This is the same Rego, packaged as an Azure Policy custom definition.

---

## P3 — restrict-model-namespace

**File:** `policies/templates/restrict-model-namespace.yaml` · `policies/constraints/restrict-model-namespace.yaml`

### What it enforces

Pods labelled `app.kubernetes.io/component: model` may only be scheduled in the
`ai-workloads` namespace. The allowed namespace is parameterised in the Constraint
(`allowedNamespace: ai-workloads`) and can be updated without modifying the template.

### Why

Model workloads (Ollama, Qdrant, future Azure AI Foundry-backed inference) have
distinct resource profiles (GPU affinity, large memory requirements), distinct security
boundaries (access to Azure AI credentials via Workload Identity), and distinct
observability requirements (LLM-specific metrics). Co-locating them with general
application workloads in the same namespace removes the ability to apply namespace-
scoped resource quotas, network policies, and RBAC boundaries specific to the AI layer.

In a multi-tenant context (Week 5+), this policy prevents a tenant from labelling
their workload as a model component to gain access to GPU node pools or Workload
Identity bindings scoped to `ai-workloads`.

### Current enforcement action: `deny`

Safe to deny immediately. A pod labelled `component: model` outside `ai-workloads` is
either a test (use a different label) or a misconfiguration. The label is explicit and
intentional — a false positive requires deliberate mislabelling.

### Escalate to `deny` when

Already `deny`. No escalation required.

### Excluded namespaces

None at constraint level — the policy applies cluster-wide. The label selector is
the scoping mechanism: unlabelled pods are unaffected.

### Azure Policy equivalent

Custom Azure Policy definition using Rego:

```rego
package restrict_model_namespace
violation[{"msg": msg}] {
  input.review.object.metadata.labels["app.kubernetes.io/component"] == "model"
  input.review.object.metadata.namespace != "ai-workloads"
  msg := "Model workloads must run in the ai-workloads namespace"
}
```

---

## P4 — require-sa-token-control

**File:** `policies/templates/require-sa-token-control.yaml` · `policies/constraints/require-sa-token-control.yaml`

### What it enforces

Every Pod must either:
- Explicitly set `spec.automountServiceAccountToken: false`, OR
- Declare the annotation `azure.workload.identity/use: "true"`

The absence of `automountServiceAccountToken` in the spec defaults to `true` at the
Kubernetes API server level — an implicit token mount. This policy makes the implicit
explicit by requiring a declared intent either way.

### Why

A mounted service account token gives the pod the ability to authenticate to the
Kubernetes API server as the pod's ServiceAccount. For most workloads — an Ollama
inference server, a Qdrant vector store, a RAG pipeline component — there is no
legitimate reason to have API server access. A mounted token in these workloads is
attack surface: a compromised pod can enumerate cluster resources, read ConfigMaps,
and potentially escalate if the ServiceAccount has overly broad permissions.

The Workload Identity exemption is intentional: Azure Workload Identity requires a
mounted projected service account token to perform the OIDC token exchange. Denying
token mounting for Workload Identity pods would silently break Azure resource access
without a clear error at configuration time.

### Current enforcement action: `warn`

Existing platform pods — Flux controllers, Kong, cert-manager — likely do not declare
`automountServiceAccountToken: false` and do not use Workload Identity. A hard `deny`
would block them on restart. Audit the violation list first.

### Escalate to `deny` when

All non-exempted pods in non-excluded namespaces either disable token automount or
declare Workload Identity intent. Audit via:

```bash
kubectl get requiresatokencontrol require-sa-token-control \
  -o jsonpath='{.status.violations}' | jq '[.[].namespace + "/" + .name] | unique'
```

Target: Week 6, after Kong and cert-manager are deployed and their service account
configurations are known. Platform components that legitimately need API server access
should use explicit ServiceAccount bindings, not the default SA with an implicit token.

### Excluded namespaces

`kube-system` · `kube-public` · `kube-node-lease` · `gatekeeper-system` · `flux-system` · `monitoring`

### Azure Policy equivalent

No direct built-in equivalent. Custom Rego:

```rego
package require_sa_token_control

token_disabled {
  input.review.object.spec.automountServiceAccountToken == false
}

has_workload_identity {
  input.review.object.metadata.annotations["azure.workload.identity/use"] == "true"
}

violation[{"msg": msg}] {
  not token_disabled
  not has_workload_identity
  msg := "Pod auto-mounts a service account token without Workload Identity intent declared"
}
```

---

## Enforcement Action Escalation Plan

| Policy | Current | Target | Target week | Condition |
|--------|---------|--------|-------------|-----------|
| require-resource-limits | `warn` | `deny` | Week 5 | Zero violations in non-excluded namespaces |
| deny-public-loadbalancer | `deny` | — | — | Already at target |
| restrict-model-namespace | `deny` | — | — | Already at target |
| require-sa-token-control | `warn` | `deny` | Week 6 | Zero violations after Kong + cert-manager deployed |

---

## Operational Reference

### Check all constraint violation counts

```bash
kubectl get requireresourcelimits,denypublicloadbalancer,\
restrictmodelnamespace,requiresatokencontrol \
  -o custom-columns=\
'NAME:.metadata.name,ENFORCEMENT:.spec.enforcementAction,VIOLATIONS:.status.totalViolations'
```

### Force an audit cycle

```bash
kubectl annotate configs config -n gatekeeper-system \
  gatekeeper.sh/force-audit="$(date +%s)" --overwrite
```

### Test a policy at admission without applying

```bash
kubectl apply --dry-run=server -f <manifest.yaml>
```

Dry-run triggers the admission webhook — policy warnings and denials surface without
creating the resource.

---

## References

- [ADR-0004 OPA Gatekeeper admission control](./adr/0004-opa-gatekeeper-admission-control.md)
- [ADR-0005 Platform ingress strategy](./adr/0005-platform-ingress-strategy.md)
- [RBAC Model](./architecture/rbac-model.md)
- [RCA: Gatekeeper Flux bootstrap namespace mismatch](./rca/rca-gatekeeper-flux-bootstrap.md)
- [OPA Gatekeeper policy library](https://github.com/open-policy-agent/gatekeeper-library)
- [Azure Policy built-in definitions for Kubernetes](https://learn.microsoft.com/en-us/azure/aks/policy-reference)
