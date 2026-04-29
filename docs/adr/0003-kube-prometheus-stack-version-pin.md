# ADR-0003: Pin kube-prometheus-stack Helm Chart Version

## Status

**Proposed**

---

## Context

The project uses `kube-prometheus-stack` as the observability foundation for a local k3d cluster that supports a 12-week AI platform engineering programme. The stack is introduced early so that platform components can be observed consistently as GitOps, ingress, policy, and model-serving capabilities are layered in over time.

The chart will later be managed through a Flux `HelmRelease`. That changes the operational model: chart resolution becomes part of the GitOps reconciliation loop instead of a one-time manual installation step. In that model, any unplanned change in chart version expands the debugging surface when a deployment fails.

`kube-prometheus-stack` is not a simple single-component chart. It tracks multiple fast-moving upstream dependencies at once, including Kubernetes compatibility, Prometheus Operator, Grafana, and chart-managed CRDs. Major version bumps have historically introduced CRD schema changes, renamed values keys, and behavioral changes that can silently invalidate an otherwise-correct values file after a `helm repo update`.

For this programme, later weeks depend on being able to distinguish between failures caused by GitOps wiring, local cluster configuration, and observability chart changes. During the Flux migration in Week 6 in particular, an unpinned chart version would introduce a confounding variable: the same manifests could begin failing solely because the chart changed underneath them.

### Drivers

| Driver | Description |
|--------|-------------|
| **Functional** | The observability stack must install reproducibly in local k3d and remain stable when later migrated to Flux `HelmRelease` management. |
| **Operational** | Debugging needs a bounded failure domain; chart behavior must not change implicitly after a repository refresh. |
| **Security** | Security updates still need to be consumed deliberately, with explicit review of upstream changes instead of automatic drift. |
| **Cost** | Pinning avoids avoidable troubleshooting and revalidation caused by unexpected upstream chart changes during the programme. |
| **Team** | The team needs predictable tooling while learning the platform stack, rather than absorbing chart release churn at the same time. |

---

## Decision

**We will pin `kube-prometheus-stack` to an explicit Helm chart version, currently `82.10.5`, instead of tracking the latest available release.**

### Rationale

This decision prioritizes repeatability and debuggability over automatic currency.

The chart releases frequently and bundles changes across several upstream components. That release pattern is valuable for staying current, but it increases the risk that a routine `helm repo update` changes rendered manifests, CRDs, default behaviors, or expected values structure without any corresponding change in this repository.

Pinning the chart version keeps the deployment input stable. If installation or reconciliation fails in later weeks, especially during the Flux `HelmRelease` migration in Week 6, the team can reason about the problem with one fewer moving part. The chart version becomes an explicit decision recorded in Git instead of an external state hidden in the local Helm cache.

This also creates a deliberate upgrade boundary. Changes to the observability stack happen only when the team chooses to review upstream release notes, validate values compatibility, and accept the operational consequences of the newer chart.

---

## Consequences

### Positive

- Makes local installs and later Flux reconciliations reproducible across machines and over time.
- Reduces the chance that a `helm repo update` silently changes chart behavior during active development.
- Keeps debugging focused on known repository changes instead of hidden upstream chart drift.

### Negative / Trade-offs

- The chart version must be bumped manually when upgrades are desired.
- Security or dependency fixes in newer chart versions are not consumed automatically.
- Upgrade work becomes an explicit maintenance task that requires compatibility review and validation.

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| A pinned chart version accumulates known bugs or security issues | Med | High | Revisit the pin when upstream publishes fixes affecting Prometheus Operator, Grafana, or chart-managed CRDs. |
| A future upgrade introduces breaking values or CRD changes | High | Med | Review the chart's upgrade guidance before every version bump and test upgrades in the local cluster before changing GitOps definitions. |
| Team members accidentally install a different chart version locally | Med | Med | Document and enforce the explicit version in Helm commands and later in Flux `HelmRelease` manifests. |

---

## Alternatives Considered

### Option A: Track the latest chart version

**Description:**

Install `kube-prometheus-stack` without specifying `--version`, allowing Helm to resolve the newest chart available after each repository refresh.

**Rejected because:**

It makes upstream chart movement an uncontrolled input and creates a hidden debugging variable, especially during later GitOps migration work.

---

### Option B: Pin only the major version line

**Description:**

Use a version constraint such as `82.x` so Helm can float to the latest patch release within the chosen major line.

**Rejected because:**

Even minor or patch-level chart changes can alter defaults, dependency versions, or upgrade requirements. The team needs exact reproducibility, not bounded drift.

---

### Option C: Vendor the chart locally

**Description:**

Copy or package the chart into the repository so no external chart resolution occurs during installation.

**Rejected because:**

It would improve reproducibility but adds unnecessary repository overhead and maintenance complexity for the current stage of the programme.

---

## Implementation Notes

### Prerequisites

- [ ] Use `--version 82.10.5` in manual Helm install and upgrade commands.
- [ ] Carry the same explicit version into the future Flux `HelmRelease` definition.

### Rollback Plan

If a planned chart bump causes incompatibility, revert to the previously pinned chart version, restore the prior values structure if needed, and reapply after reviewing the chart's upgrade guidance and CRD requirements.

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

- `kube-prometheus-stack` chart release currently selected: `82.10.5`
- `kube-prometheus-stack` Artifact Hub page: https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack
- `kube-prometheus-stack` upgrade guidance: https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/UPGRADE.md
- [docs/adr/README.md](./README.md)
- [docs/adr/template.md](./template.md)