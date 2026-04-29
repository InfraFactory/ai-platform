# ADR-0002: Pin Local Kubernetes to AKS GA-Compatible v1.34

## Status

**Proposed**

---

## Context

The project uses a local-first k3d cluster as the primary execution environment for a 12-week learning programme. The local cluster must remain close enough to a valid Azure Kubernetes Service (AKS) target that platform work done locally can be validated in AKS without introducing a mid-programme Kubernetes version migration.

Week 6 includes an AKS burst validation step in Australia East. That makes the Kubernetes version pin more than a local convenience setting: it is a compatibility contract between local development and the cloud validation environment.

The current local pin of `rancher/k3s:v1.31.4-k3s1` is no longer a strong fit for that goal. While it may remain usable through AKS long-term support channels, it is no longer aligned with standard-support AKS planning. Choosing too new a version creates a different problem: the local environment may outrun AKS general availability in the target region, making the validation step impossible or forcing a downgrade.

The team therefore needs a Kubernetes version that is stable now, remains a valid AKS GA target for the duration of the programme, and is mature enough that the surrounding operator ecosystem has already absorbed the version change.

### Drivers

| Driver | Description |
|--------|-------------|
| **Functional** | The local k3d cluster must support all planned platform work and remain compatible with a valid AKS target in Australia East through the full 12-week programme. |
| **Operational** | The version pin must avoid a forced mid-programme upgrade that would interrupt delivery around the AKS validation milestone. |
| **Security** | The cluster should stay on a generally available, standard-support Kubernetes line rather than relying on an aging version kept alive only through extended support posture. |
| **Cost** | Avoiding a mid-stream version migration reduces rework, duplicate validation effort, and troubleshooting time during the programme. |
| **Team** | The team needs a conservative, predictable baseline that reduces cognitive load while learning Flux, Argo CD, Prometheus, cert-manager, and policy tooling. |

---

## Decision

**We will pin the local k3d cluster to `rancher/k3s:v1.34.3-k3s1`, which provides Kubernetes v1.34.3 as the baseline version for the programme.**

### Rationale

This version is the best fit across programme duration, AKS regional support, and ecosystem maturity.

`v1.35` was rejected because it is preview-only in AKS Australia East and therefore does not satisfy the Week 6 requirement for GA-backed validation. A preview-only target would couple the local platform baseline to a cloud feature that may change during the programme.

`v1.33` was rejected because it is currently viable but likely to become `N-2` within roughly 2 to 3 months if `v1.35` reaches AKS GA during the programme. That creates a credible risk of landing in a support-transition window around Weeks 8 to 9 and forcing an avoidable upgrade after the environment is already in active use.

`v1.34` is the current `N` line in AKS Australia East and offers the most balanced choice: current GA availability, standard support posture, and enough time in the ecosystem for core platform components such as Flux, Argo CD, kube-prometheus-stack, cert-manager, and OPA Gatekeeper to have validated against it.

This decision intentionally prefers a mature current GA line over both the latest available upstream line and the oldest still-supported cloud line. That trade-off reduces upgrade churn without accepting unnecessary lag.

---

## Consequences

### Positive

- Keeps the local k3d baseline aligned with a valid AKS GA target in Australia East for the planned validation step.
- Reduces the chance of a disruptive Kubernetes upgrade during the 12-week programme.
- Places the platform on a version that is current enough for support confidence but mature enough for operator ecosystem stability.

### Negative / Trade-offs

- The local cluster will not track the newest available K3s or Kubernetes release line.
- A future move to `v1.35` or later will still be required once that line becomes the better AKS-aligned baseline.
- Pinning to a specific patch version means explicit maintenance work is needed if a later `v1.34.x` patch becomes desirable.

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| AKS support posture changes faster than expected during the programme | Med | High | Recheck AKS Australia East version availability before Week 6 and again before any production-like validation activity. |
| A core operator publishes a known incompatibility with Kubernetes v1.34 | Low | High | Fall back to `v1.33.7` after validating that it remains an AKS-supported GA target for the remaining programme duration. |
| The chosen patch version accumulates known defects fixed in later `v1.34.x` releases | Med | Med | Review `v1.34.x` patch releases periodically and update the pin only within the same minor line unless a stronger reason emerges. |

---

## Alternatives Considered

### Option A: Pin to `rancher/k3s:v1.35.0-k3s1`

**Description:**

Use the newest available upstream minor line to maximize currency.

**Rejected because:**

`v1.35` is preview-only in AKS Australia East and therefore does not provide a reliable GA validation target for the programme.

---

### Option B: Pin to `rancher/k3s:v1.33.7-k3s1`

**Description:**

Use the current `N-1` line to stay conservative while retaining standard support.

**Rejected because:**

It is valid now but risks becoming `N-2` during the programme, which could force an upgrade interruption around Weeks 8 to 9.

---

### Option C: Keep `rancher/k3s:v1.31.4-k3s1`

**Description:**

Retain the original local cluster pin to avoid immediate change.

**Rejected because:**

It relies on an older AKS posture and is no longer aligned with the desired standard-support baseline for the programme.

---

## Implementation Notes

### Prerequisites

- [ ] Update the `image` field in the local k3d config to `rancher/k3s:v1.34.3-k3s1`.
- [ ] Recreate the local cluster and rerun core bootstrap validation, including monitoring and GitOps components.

### Rollback Plan

If the pinned version causes incompatibility with a core platform operator, revert the k3d image pin to `rancher/k3s:v1.33.7-k3s1`, recreate the cluster, and repeat bootstrap validation. Do not roll back to `v1.31.4-k3s1` unless AKS support posture or tooling constraints leave no viable GA alternative.

---

## Review

| Field | Value |
|-------|-------|
| **Date** | 2026-03-19 |
| **Author(s)** | io |
| **Reviewed by** | N/A |
| **Project phase / Week** | Week 0 |
| **Next review date** | 2026-05-01 |

---

## References

- AKS regional version availability check via `az aks get-versions --location australiaeast`
- K3s release stream for available pinned versions: https://github.com/k3s-io/k3s/releases
- [docs/adr/README.md](./README.md)
- [docs/adr/template.md](./template.md)