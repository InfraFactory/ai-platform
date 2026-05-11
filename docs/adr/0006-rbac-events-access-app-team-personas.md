# ADR-0006: Retain Events Read Access in namespace-developer and Restrict Secrets List in cluster-observer

## Status

**Accepted**

---

## Context

The Cloudville AI Platform RBAC model defines four ClusterRoles (`platform-admin`,
`namespace-developer`, `ci-deployer`, `cluster-observer`) aligned to five personas.
During Week 2 governance work, a DEVIATE task was run to evaluate whether `events`
read access in `namespace-developer` was a genuine functional requirement or a
convenience grant inconsistent with the model's least-privilege principle.

A test namespace (`deviate-test`) was created with a RoleBinding wiring a simulated
P2 ServiceAccount to `namespace-developer`. The `events` stanza was removed from
the ClusterRole. A deliberately broken workload (bad image tag: `nginx:this-tag-does-not-exist`)
was deployed and observed from both P2 and platform-admin perspectives.

During the same review, an incorrect inline comment in `cluster-observer` was
identified: the `secrets` rule granted `list` with a comment claiming it returns
metadata only. This is factually wrong — `list` on secrets returns full secret
data (base64-encoded). This was caught before P3 bindings became active.
**Corrected and applied — 2026-05-01.**

A secondary finding emerged during the experiment: a `K8sNoUseDefaultServiceAccount`
ConstraintTemplate and Constraint were authored but not referenced in the
`policies/templates/kustomization.yaml` and `policies/constraints/kustomization.yaml`
manifests. Flux therefore never reconciled them into the cluster — the test pod
used the `default` ServiceAccount and was not blocked. This revealed a systematic
risk: policy files on disk that are absent from kustomization resources are
documentation, not enforcement. **Kustomization corrected and pod blocking
confirmed — 2026-05-01.**

### Drivers

| Driver | Description |
|--------|-------------|
| **Functional** | App teams (P2) must be able to perform first-line diagnosis of workload failures without escalating to the platform team |
| **Operational** | Events are the primary diagnostic layer for failure modes that produce empty logs or never-ready pods (`ImagePullBackOff`, `OOMKilled`, scheduler-driven `Pending`) |
| **Security** | Least-privilege must distinguish between operational access (what a persona can *do*) and observational access (what a persona can *know*); over-granting on `cluster-observer` secrets is a real exposure if P3 bindings activate before correction; default ServiceAccount use must be enforced at admission, not just documented |
| **Cost** | No cost implication |
| **Team** | Platform decisions are modelled against large platform team norms — enforcement depth should reflect what a mature platform would implement, not minimum viable for a single engineer |

---

## Decision

**We will retain `events` read access (`get`, `list`, `watch`) in `namespace-developer`;
restrict `cluster-observer` secrets access to `get` only; and enforce the prohibition
on the `default` ServiceAccount via dual-layer Gatekeeper admission control covering
both Pod and workload controller (Deployment, StatefulSet, Job, CronJob) object kinds.**

### Rationale

**Events access:** The DEVIATE experiment produced a clear result. With `events` removed,
a pod in `ImagePullBackOff` showed `Events: <none>` from P2's perspective. The pod was
visibly broken — status string present, three of five Conditions showing `True` — but the
cause was invisible. P2 could not distinguish a bad image tag (`rpc error: NotFound`) from
an auth failure (`Unauthorized`), a rate limit (`429`), or a network issue. All four produce
the same `ImagePullBackOff` status; only the event message disambiguates them into
actionable categories.

Events are written exclusively by system components — kubelet, scheduler, replication
controller. App teams cannot mutate events. Granting `events` read access does not expand
P2's operational surface; it expands their observational surface. This is a different
category of access than granting `pods/exec` or `secrets` write — those expand what P2
can *do*. Events expand only what P2 can *know* about what the platform did on their behalf.

**Secrets restriction on cluster-observer:** The `list` verb on secrets was corrected under
the same principle applied in reverse. The `PartialObjectMetadata` pattern exists but
requires explicit client-side opt-in; `kubectl get secrets` does not use it. P3 should
inspect named secrets (`get`) but must not enumerate all secret values cluster-wide in a
single call.

**Dual-layer default SA enforcement:** The platform models decisions against large platform
team norms. On a platform with multiple engineers, GitOps pipelines, and diverse workload
authors, a single enforcement layer is insufficient:

- **Pod-level admission** is the non-bypassable backstop. Every workload type — Deployment,
  StatefulSet, Job, CronJob, naked Pod — eventually creates a Pod. If the Pod is rejected,
  the workload cannot run regardless of what created it. One policy path, full coverage.

- **Workload controller-level admission** (Deployment, StatefulSet, Job, CronJob) provides
  fast feedback at apply time. The failing object is the one the operator applied — the
  failure is immediate and unambiguous, rather than surfacing later when the ReplicaSet
  attempts to schedule a Pod. In a CI/CD pipeline context this is the difference between a
  blocked `kubectl apply` and a silently unhealthy rollout.

The two layers are complementary, not redundant. Pod-level is bypass-proof; controller-level
is developer-friendly. Both are justified at the enforcement depth this platform targets.

This decision formalises two principles that apply to all subsequent RBAC and policy work:

> RBAC governs two separable concerns — the ability to perform operations, and the ability
> to observe the system's accounting of those operations. Least-privilege reasoning that
> addresses only the former will systematically under-grant observability access, producing
> personas that can act but cannot reason about system behaviour. Every read-only access
> decision must be evaluated against both dimensions.

> Policy files not referenced in kustomization resources are documentation, not enforcement.
> The gap between "in the repo" and "reconciled into the cluster" is a governance risk and
> must be verified explicitly after every new policy is authored.

---

## Consequences

### Positive

- App teams retain diagnostic capability for the failure modes that matter most —
  the ones where application logs are empty because the container never started
- The principles established here are reusable as a decision framework for all RBAC
  scoping in Weeks 5–10 (tenant namespace vending, CI SA scoping, observer bindings,
  break-glass procedure)
- The `cluster-observer` secrets over-grant is corrected before P3 bindings become
  active at Week 8, eliminating a real exposure window
- Event history survives object deletion (default 1h TTL) — P2 can diagnose pods
  that crashed and were replaced without platform team involvement
- Dual-layer SA enforcement provides both immediate developer feedback (controller
  admission) and a bypass-proof backstop (Pod admission), reflecting mature platform
  engineering practice
- The kustomization gap finding establishes a verification discipline: `kubectl get
  constrainttemplates` output must match what is expected from the repo after every
  new policy file is authored

### Negative / Trade-offs

- `events` read access exposes workload scheduling history, node assignment, and image
  references to P2 personas; acceptable only because P2 bindings are namespace-scoped
  (RoleBinding, not ClusterRoleBinding) — a tenant sees only events in their own namespace
- Restricting `cluster-observer` secrets to `get` only means P3 cannot list all secrets
  for bulk audit; they must know the secret name in advance; runbooks for P3 audit
  workflows must account for this when bindings are activated at Week 8
- Dual-layer Gatekeeper enforcement increases policy maintenance surface: the Rego for
  workload controller kinds must traverse `spec.template.spec.serviceAccountName`
  (Deployment, StatefulSet, Job) and `spec.jobTemplate.spec.template.spec.serviceAccountName`
  (CronJob) — each schema path must be explicitly handled and kept current as new workload
  types are introduced

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Tenant namespace RoleBinding accidentally created as ClusterRoleBinding for events, granting cross-tenant event visibility | Med | High | Gatekeeper constraint to enforce RoleBinding (not ClusterRoleBinding) for namespace-scoped roles at Week 5 namespace vending |
| `cluster-observer` secrets restriction breaks a P3 audit workflow when bindings become active | Low | Low | P3 bindings not yet active; correction applied before activation; runbook to be documented at Week 8 |
| Future operator restores `list` to `cluster-observer` secrets without understanding the data exposure | Low | High | This ADR is referenced in the RBAC model; ConstraintTemplate for secrets list on observer roles is a Week 8 candidate |
| New workload type introduced whose schema path is not covered by workload controller-level Rego | Med | Med | Pod-level admission remains the bypass-proof backstop; new kinds added to the constraint match block as they are introduced to the platform |
| New policy file authored but not added to kustomization — silent enforcement gap | Med | High | Post-authoring verification step: `kubectl get constrainttemplates` compared to repo directory listing; add to platform runbook |

---

## Alternatives Considered

### Option A: Remove events access from `namespace-developer`

**Description:** Treat events as a convenience grant inconsistent with least-privilege.
App teams have pod status, deployment status, and pod logs — sufficient for operational
awareness.

**Rejected because:** The experiment demonstrated this is wrong. Pod status and logs do
not cover the failure modes where events are the *only* diagnostic signal: `ImagePullBackOff`
(container never starts, no app logs), `OOMKilled` before stdout is established, and
scheduler-driven `Pending` (node affinity, resource pressure). Removing events access
shifts first-line diagnosis to the platform team, which is the opposite of the model's
design intent and does not reduce P2's operational attack surface by any meaningful amount.

---

### Option B: Provide events access via a separate opt-in role

**Description:** Remove events from `namespace-developer` base role; create a separate
`events-reader` role bound on request per namespace.

**Rejected because:** Events contain no secret data and grant no operational capability.
The per-namespace binding overhead is not justified by any marginal security gain, and
introduces process friction that degrades the app team experience without a corresponding
security benefit.

---

### Option C: Retain `list` on secrets in `cluster-observer`

**Description:** Accept the existing rule as-is; the observer role is cluster-wide
read-only and full secret enumeration is consistent with an audit persona.

**Rejected because:** The inline comment claiming `list` returns metadata only is
factually incorrect — the access granted exceeded what was intentionally designed. A
P3 observer enumerating all secret values across all namespaces in a single API call
is a significant over-grant. The correct access for P3 is named-secret inspection
(`get`), not cluster-wide enumeration.

---

### Option D: Pod-level admission only for default SA enforcement

**Description:** Enforce the default SA prohibition only at Pod admission. Pod-level
enforcement is bypass-proof — all workload types eventually create Pods — so
controller-level enforcement is redundant.

**Rejected because:** Pod-level enforcement alone defers failure to the point where the
ReplicaSet attempts to schedule a Pod, not when the operator applies the Deployment. On
a platform with CI/CD pipelines and multiple workload authors, this produces failures
that appear as unhealthy rollouts rather than blocked applies — harder to diagnose,
slower to surface, and inconsistent with the fast-feedback principle that underpins
mature platform engineering practice. Controller-level admission catches the violation
at the earliest possible point in the apply path; Pod-level remains the non-bypassable
backstop. Both layers are warranted at the enforcement depth this platform targets.

---

## Implementation Notes

### Changes to `namespace-developer`

No change required — the `events` stanza is retained as originally authored.
The DEVIATE task confirmed the existing rule is correct; this ADR documents the
reasoning that was previously implicit.

```yaml
# Retain in namespace-developer — confirmed necessary by DEVIATE experiment
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
```

### Changes to `cluster-observer` — Applied 2026-05-01

```yaml
# Before
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list"]   # metadata only — data field requires explicit get on a named secret

# After
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]   # named-secret inspection only; list returns full base64 data — not appropriate for observer persona
```

### Gatekeeper Enforcement for Default ServiceAccount — Applied 2026-05-01

Dual-layer enforcement. The ConstraintTemplate covers both Pod-level (bypass-proof
backstop) and workload controller kinds (fast feedback at apply time).

**ConstraintTemplate** (`policies/templates/deny-default-sa-use.yaml`):

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8snousedefaultserviceaccount
spec:
  crd:
    spec:
      names:
        kind: K8sNoUseDefaultServiceAccount
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8snousedefaultserviceaccount

        # --- Pod-level (bypass-proof backstop) ---
        violation[{"msg": msg}] {
          input.review.kind.kind == "Pod"
          input.review.object.spec.serviceAccountName == "default"
          msg := sprintf("Pod '%v' uses the default ServiceAccount. Specify an explicit serviceAccountName.", [input.review.object.metadata.name])
        }
        violation[{"msg": msg}] {
          input.review.kind.kind == "Pod"
          not input.review.object.spec.serviceAccountName
          msg := sprintf("Pod '%v' omits serviceAccountName — resolves to default. This is forbidden.", [input.review.object.metadata.name])
        }

        # --- Workload controller-level (fast feedback at apply time) ---
        workload_kinds := {"Deployment", "StatefulSet", "Job"}

        violation[{"msg": msg}] {
          workload_kinds[input.review.kind.kind]
          input.review.object.spec.template.spec.serviceAccountName == "default"
          msg := sprintf("%v '%v' sets serviceAccountName to default in pod template. Specify an explicit serviceAccountName.", [input.review.kind.kind, input.review.object.metadata.name])
        }
        violation[{"msg": msg}] {
          workload_kinds[input.review.kind.kind]
          not input.review.object.spec.template.spec.serviceAccountName
          msg := sprintf("%v '%v' omits serviceAccountName in pod template — resolves to default. This is forbidden.", [input.review.kind.kind, input.review.object.metadata.name])
        }

        violation[{"msg": msg}] {
          input.review.kind.kind == "CronJob"
          input.review.object.spec.jobTemplate.spec.template.spec.serviceAccountName == "default"
          msg := sprintf("CronJob '%v' sets serviceAccountName to default in job template. Specify an explicit serviceAccountName.", [input.review.object.metadata.name])
        }
        violation[{"msg": msg}] {
          input.review.kind.kind == "CronJob"
          not input.review.object.spec.jobTemplate.spec.template.spec.serviceAccountName
          msg := sprintf("CronJob '%v' omits serviceAccountName in job template — resolves to default. This is forbidden.", [input.review.object.metadata.name])
        }
```

**Constraint** (`policies/constraints/deny-default-sa-use.yaml`):

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sNoUseDefaultServiceAccount
metadata:
  name: no-default-serviceaccount
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
      - apiGroups: ["apps"]
        kinds: ["Deployment", "StatefulSet"]
      - apiGroups: ["batch"]
        kinds: ["Job", "CronJob"]
    excludedNamespaces:
      - kube-system
      - gatekeeper-system
      - flux-system
      - monitoring
```

**Kustomization references added to both manifest files:**

```yaml
# policies/templates/kustomization.yaml  AND  policies/constraints/kustomization.yaml
resources:
  - ...existing entries...
  - deny-default-sa-use.yaml
```

**Verification — pod blocking confirmed 2026-05-01.**

### Prerequisites

- [x] DEVIATE experiment completed — events removal and restoration verified
- [x] `cluster-observer` secrets over-grant identified and corrected
- [x] `K8sNoUseDefaultServiceAccount` ConstraintTemplate and Constraint authored
- [x] Kustomization manifests updated to reference new policy files
- [x] Flux reconciliation confirmed — pod blocking verified in cluster
- [ ] Workload controller-level Rego extended if new workload types are introduced to the platform
- [ ] P3 audit runbook documented before Week 8 binding activation

### Rollback Plan

**Events access:** If `events` read access creates an unexpected exposure in the
multi-tenant context at Week 5, scope can be restricted via a Gatekeeper constraint
rather than modifying the ClusterRole — allowing finer-grained control per namespace
without breaking the base role.

**Secrets restriction:** If the `get`-only constraint breaks a P3 audit workflow at
Week 8, restore `list` temporarily and update the runbook before re-restricting. Do
not leave `list` in place permanently.

**Default SA enforcement:** To temporarily disable enforcement during a platform
incident, patch the constraint to `dryrun` — do not delete it. This preserves audit
visibility while removing the admission block.

```bash
kubectl patch k8snousedefaultserviceaccount no-default-serviceaccount \
  --type=merge -p '{"spec":{"enforcementAction":"dryrun"}}'
# Restore after incident resolution:
kubectl patch k8snousedefaultserviceaccount no-default-serviceaccount \
  --type=merge -p '{"spec":{"enforcementAction":"deny"}}'
```

---

## Review

| Field | Value |
|-------|-------|
| **Date** | 2026-05-01 |
| **Author(s)** | Israel |
| **Reviewed by** | — |
| **Project phase / Week** | Phase 1 · Week 2 — Governance, Identity & Zero-Trust |
| **Next review date** | 2026-06-12 (Week 5 — tenant namespace vending; verify RoleBinding scope for events; extend constraint kinds if new workload types introduced) |

---

## References

- `docs/rbac-model.md` — section 1.1 (`namespace-developer`, `cluster-observer`), section 1.4 (SA conventions), section 1.5 (Policy Enforcement Gap)
- [ADR-0004 OPA Gatekeeper admission control](./0004-opa-gatekeeper-admission-control.md)
- [ADR-0005 Platform ingress strategy](./0005-platform-ingress-strategy.md)
- [Kubernetes Events API](https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [PartialObjectMetadata — Kubernetes API conventions](https://kubernetes.io/docs/reference/using-api/api-concepts/#receiving-resources-as-tables)
- [OPA Gatekeeper ConstraintTemplate spec](https://open-policy-agent.github.io/gatekeeper/website/docs/constrainttemplates)
