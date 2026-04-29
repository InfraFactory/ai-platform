# RCA: Gatekeeper Deployed to Wrong Namespace via Flux HelmRelease

**Date:** 2026-04-30  
**Severity:** Low (local k3d lab environment, no production impact)  
**Resolution time:** ~45 minutes  
**Status:** Resolved

---

## Summary

Gatekeeper was deployed into `flux-system` instead of `gatekeeper-system` because
`targetNamespace` was omitted from the initial HelmRelease spec. A subsequent attempt
to correct this triggered a webhook-induced reconciliation deadlock: Gatekeeper's
admission webhook (registered against the old `flux-system` service endpoint) began
intercepting Flux's own dry-run operations, returning 502 errors that blocked the
very reconciliation needed to fix it.

Resolution required manually deleting both webhook configurations to break the
deadlock, uninstalling the misplaced Helm release, and forcing a clean reinstall
via Flux.

---

## Timeline

| Time | Event |
|------|-------|
| T+0  | Gatekeeper HelmRelease created without `targetNamespace`. Flux reconciles successfully. |
| T+5  | Pods observed running in `flux-system` instead of `gatekeeper-system`. |
| T+10 | `targetNamespace: gatekeeper-system` added to HelmRelease and committed. |
| T+15 | `opa-gatekeeper` kustomization stuck on old revision `c2130cc2` — not picking up the change. |
| T+18 | Kustomization error observed: `check-ignore-label.gatekeeper.sh` webhook returning 502 on Flux's dry-run of `Namespace/gatekeeper-system`. |
| T+20 | Root cause identified: Gatekeeper webhook registered at `gatekeeper-webhook-service.flux-system.svc:443` intercepting Flux's own admission operations. |
| T+25 | Both `ValidatingWebhookConfiguration` and `MutatingWebhookConfiguration` deleted to break the deadlock. |
| T+28 | Gatekeeper Helm release uninstalled from `flux-system`. |
| T+30 | Kustomization force-reconciled — live HelmRelease object now contains `targetNamespace: gatekeeper-system`. |
| T+35 | HelmRelease resumed. Flux reinstalls Gatekeeper into `gatekeeper-system`. |
| T+40 | Pods confirmed running in `gatekeeper-system`. Webhook re-registered at correct service endpoint. |

---

## Root Cause Analysis

### Primary cause: Missing `targetNamespace` in HelmRelease

When a Flux `HelmRelease` object does not specify `targetNamespace`, Helm deploys all
chart resources into the namespace where the `HelmRelease` object itself lives — in
this case, `flux-system`. Gatekeeper's chart does not set a hard-coded namespace in
its templates (it uses `.Release.Namespace`), so it silently accepted whatever
namespace Helm provided.

The Helm install reported success (`Helm install succeeded`) because from Helm's
perspective it was a valid operation. Flux had no basis to flag it as an error.

### Secondary cause: Webhook-induced reconciliation deadlock

Gatekeeper installs two webhook configurations at deploy time:

- `gatekeeper-validating-webhook-configuration`
- `gatekeeper-mutating-webhook-configuration`

Both registered their endpoint as `gatekeeper-webhook-service.flux-system.svc:443` —
correct relative to where Gatekeeper actually landed, but wrong relative to where it
*should* have landed.

When the corrected HelmRelease was committed and Flux attempted to reconcile, it
performed a dry-run of the `Namespace/gatekeeper-system` manifest as part of the
`opa-gatekeeper` kustomization. The `check-ignore-label.gatekeeper.sh` webhook fired
against this dry-run request (Gatekeeper intercepts namespace creation to check for
its exemption label). The webhook service was still alive in `flux-system`, but the
request handling returned 502 — likely because Gatekeeper's internal state was
partially inconsistent at that point.

This created a deadlock:

```
Flux needs to reconcile opa-gatekeeper kustomization
  → Flux dry-runs Namespace/gatekeeper-system
    → Gatekeeper webhook intercepts
      → Webhook returns 502
        → Flux reconciliation fails
          → targetNamespace change never lands in live HelmRelease
            → Gatekeeper stays in flux-system
              → Gatekeeper webhook stays registered at flux-system endpoint
                → loop
```

---

## Contributing Factors

**1. No `targetNamespace` in HelmRelease is not an error.**  
Flux and Helm treat a missing `targetNamespace` as "use the HelmRelease object's
namespace." There is no warning. This is a footgun for platform components that have
their own dedicated namespace.

**2. Gatekeeper webhooks fire on Flux's own operations.**  
Flux performs dry-runs against the API server during reconciliation. These dry-runs
are subject to admission webhooks. A misbehaving or misconfigured Gatekeeper
installation can block Flux itself — a particularly bad failure mode because Flux is
the remediation mechanism.

**3. The `gatekeeper-system` namespace was pre-created independently of the HelmRelease.**  
`createNamespace: false` was set because the namespace was managed as a separate
manifest. However, the namespace creation predates Gatekeeper's webhook registration,
so when Flux later tried to dry-run the namespace (to apply the `opa-gatekeeper`
kustomization), Gatekeeper's webhook intercepted it without the exemption label in
place.

**4. No early namespace validation.**  
The initial deploy did not verify pod placement before moving on. A simple
`kubectl get pods --all-namespaces | grep gatekeeper` immediately after the HelmRelease
reconciled would have caught this in under 30 seconds.

---

## Resolution

```bash
# Step 1: Break the deadlock by removing both webhook configurations
kubectl delete validatingwebhookconfiguration gatekeeper-validating-webhook-configuration
kubectl delete mutatingwebhookconfiguration gatekeeper-mutating-webhook-configuration

# Step 2: Suspend Flux management and uninstall the misplaced release
flux suspend helmrelease gatekeeper -n flux-system
helm uninstall gatekeeper -n flux-system

# Step 3: Force Flux to reconcile the kustomization — picks up targetNamespace
flux reconcile kustomization opa-gatekeeper --with-source

# Step 4: Verify targetNamespace is now in the live HelmRelease object
kubectl get helmrelease gatekeeper -n flux-system -o jsonpath='{.spec.targetNamespace}'
# Expected output: gatekeeper-system

# Step 5: Resume — Flux reinstalls Gatekeeper into the correct namespace
flux resume helmrelease gatekeeper -n flux-system

# Step 6: Confirm
kubectl get pods --all-namespaces | grep gatekeeper
# Expected: both pods in gatekeeper-system
```

---

## Prevention

### Immediate: Always specify `targetNamespace` for platform components

Any HelmRelease deploying a component with its own namespace must explicitly declare
`targetNamespace`. Treat its absence as a misconfiguration, not a valid default.

```yaml
spec:
  targetNamespace: gatekeeper-system   # always explicit
  install:
    createNamespace: false             # namespace managed by Flux manifest
```

### Immediate: Verify pod placement after every HelmRelease reconciliation

```bash
# After any HelmRelease reconciles, verify before moving on
kubectl get pods --all-namespaces | grep <component>
```

### Architectural: Add Gatekeeper's own namespace to the webhook exemption list

Gatekeeper supports `exemptNamespaces` and `exemptNamespacePrefixes` in its values.
The `flux-system` namespace should be exempted to prevent Gatekeeper from intercepting
Flux's own operations:

```yaml
values:
  exemptNamespaces:
    - flux-system
    - kube-system
    - gatekeeper-system
```

This is especially important during bootstrapping when Gatekeeper may be partially
initialised.

### Architectural: Label Flux-managed namespaces with Gatekeeper's exemption label

Gatekeeper checks for `admission.gatekeeper.sh/ignore: "no-self-managing"` on
namespaces during the `check-ignore-label.gatekeeper.sh` webhook call. Flux-system
namespace manifests should carry this label to prevent Gatekeeper from intercepting
Flux reconciliation operations at the admission layer.

---

## Lessons

**Admission webhooks that intercept infrastructure tooling are a class of failure worth
anticipating upfront.** Gatekeeper's `check-ignore-label` webhook is not optional — it
fires on every namespace create/update. In a GitOps environment where the GitOps
controller is also managing the webhook's host component, a misconfigured webhook can
make the system self-healing impossible. The right posture is to exempt GitOps
controller namespaces from all admission webhooks before enabling enforcement.

**The Helm success message is not a deployment success message.** `Helm install
succeeded` confirms the API server accepted the manifests. It says nothing about
whether the resources landed where you intended. Namespace placement must be
verified out-of-band.
