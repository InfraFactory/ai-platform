# ADR-0005: Platform Ingress Strategy Following ingress-nginx Retirement

## Status

**Accepted**

---

## Context

The ingress-nginx controller — the dominant Kubernetes ingress implementation for the
past six years — was formally retired in November 2025. The retirement was announced
by the Kubernetes project itself, not a third party, and was accompanied by a formal
migration path to Gateway API. The upstream project has signalled no further feature
development; only critical security patches will be applied during a wind-down period.

This has a direct consequence for this platform. The OPA policy being authored in
Week 2 includes a `LoadBalancer` service type restriction with a namespace exemption
list. That exemption list must name the ingress controller namespace. If ingress-nginx
is in the exemption list, the exemption references a retiring component — a
maintenance liability from day one.

Additionally, Week 3 requires an API gateway selection decision (Kong vs Traefik vs
NGINX vs APIM). That decision must be made against the current ingress landscape, not
the pre-2025 landscape where ingress-nginx was a reasonable default.

The broader context: the Kubernetes project has been migrating the ingress surface
to Gateway API since v1.0 (October 2023). Gateway API provides:

- Role-based resource model (`Gateway`, `GatewayClass`, `HTTPRoute`, `GRPCRoute`)
  separating infrastructure operator concerns from application developer concerns
- First-class support for traffic splitting, header manipulation, and request mirroring
  without annotations
- A common API implemented by multiple backends (Kong, Traefik, Envoy, Istio, Azure
  Application Gateway for Containers)
- A clear extension model that does not rely on controller-specific annotation strings

### Drivers

| Driver | Description |
|--------|-------------|
| **Functional** | The platform needs an ingress layer for Weeks 3–10; it must survive the programme's full duration |
| **Operational** | The ingress controller is in the Flux-owned platform layer; changes require GitOps-managed upgrades |
| **Security** | The controller namespace appears in the Gatekeeper LoadBalancer exemption list; a wrong choice here propagates into policy |
| **Cost** | No additional cloud spend; ingress runs in-cluster |
| **Architecture** | Azure Application Gateway for Containers implements Gateway API natively — local Gateway API resources should map forward to Azure without a rewrite |
| **Team** | Single operator; the ingress model must be learnable without a dedicated networking team |

---

## Decision

**We will not use ingress-nginx. Gateway API is the platform ingress standard.
Kong (deployed in Week 3) is the current Gateway API implementation for this
programme, operating in the `kong` namespace.**

The `LoadBalancer` OPA policy exemption list references `kong`, not `ingress-nginx`.
All ingress resources in the `applications/` layer will be authored as `HTTPRoute`
resources targeting a `Gateway`, not as legacy `Ingress` resources.

On AKS, the equivalent is Azure Application Gateway for Containers (AGC), which
implements Gateway API natively. Kong can also run on AKS as a self-managed
alternative with no configuration translation required.

### Rationale

**Why not ingress-nginx despite its familiarity:**
The retirement is not a deprecation with a long tail — it is an end-of-life event.
Continuing to build against ingress-nginx means accepting that the component will
eventually stop receiving security patches, that the community will progressively
defocus from it, and that a migration will be unavoidable at an inconvenient time.
The transition cost is lower now, during a greenfield build, than it will be in 12
months when production traffic is flowing.

**Why Gateway API over the legacy Ingress resource:**
The `Ingress` resource API is frozen. No new capabilities will be added. Controller-
specific behaviour is encoded in annotations — a string-based escape hatch that varies
between implementations and cannot be validated or typed. Gateway API resources are
typed, role-scoped, and implemented consistently across backends. An `HTTPRoute` that
works against Kong locally requires no translation to work against AGC on AKS — the
same manifest, different `GatewayClass`.

**Why Kong as the current implementation:**
Kong is Week 3's primary build target per the programme plan, and it supports both
the legacy Ingress resource and Gateway API, allowing progressive migration of any
existing resources. Kong's control plane also functions as an API gateway — rate
limiting, authentication plugins, and tenant routing are applied at the same layer as
ingress, which is the Week 3 objective. Using Kong for both ingress and API gateway
avoids introducing a second data plane component.

Traefik is the legitimate alternative — see Options below. The decision between Kong
and Traefik is deferred to the Week 3 ADR (`ADR-0006-api-gateway-selection.md`)
where load testing and plugin behaviour can be evaluated directly. For the purpose of
this ADR — naming the ingress namespace for the OPA exemption — `kong` is the
committed namespace regardless of how the Week 3 ADR resolves (Traefik also runs in
a `traefik` namespace if selected, and the OPA policy will be updated accordingly).

---

## Consequences

### Positive

- `HTTPRoute` resources are portable across Gateway API implementations — Kong local,
  AGC on AKS, Istio on a future service mesh layer — without annotation translation
- The role separation in Gateway API (infrastructure owner manages `Gateway`;
  application team manages `HTTPRoute`) directly maps to the platform/app team RBAC
  model being built in Week 2
- Gatekeeper OPA policies targeting `HTTPRoute` instead of `Ingress` are more
  expressive — route-level controls are available as first-class fields, not
  annotation strings
- No dependency on a retiring component; security patch exposure is from the
  implementation (Kong/Traefik), which are actively maintained projects

### Negative / Trade-offs

- Gateway API adds resource complexity: `GatewayClass`, `Gateway`, `HTTPRoute`
  replace a single `Ingress` resource; the learning curve is steeper for application
  developers
- Not all tooling has caught up with Gateway API — some Helm charts still generate
  `Ingress` resources; these require either chart-level overrides or a parallel
  `HTTPRoute` until upstream charts are updated
- The `Ingress` resource is not being removed from Kubernetes — it is simply frozen.
  Legacy resources from older Helm charts will continue to work through controller
  backwards compatibility, but should be treated as technical debt

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Week 3 ADR selects Traefik over Kong, requiring OPA policy namespace update | Med | Low | OPA constraint uses a parameters list — update is a one-line change in the Constraint manifest |
| Application Helm charts generate `Ingress` not `HTTPRoute` | High | Low | Accept as technical debt for learning purposes; document the gap; migrate chart-by-chart |
| Azure Application Gateway for Containers is not available in Australia East | Low | Med | Verify region availability at Week 9 (AKS validation); fallback is NGINX Gateway Fabric or Kong on AKS |
| Gateway API version skew between local Kong and AKS AGC | Low | Med | Pin to Gateway API v1.1+ resources (`HTTPRoute` GA); avoid experimental resources until AKS support is confirmed |

---

## Alternatives Considered

### Option A: Continue using ingress-nginx during the programme, migrate after

**Description:** ingress-nginx still functions; the retirement does not immediately
break clusters using it. The programme could use it for familiarity and migrate at
the end.

**Rejected because:** The programme's explicit goal is to build architectural thinking
that reflects current and forward-looking practice. Building against a retired
component would mean producing a portfolio that demonstrates competence in a pattern
the industry is actively moving away from. The migration cost during a greenfield
programme is near zero; the cost of demonstrating ingress-nginx expertise in a
2026 portfolio is reputational.

---

### Option B: Traefik as the Gateway API implementation

**Description:** Traefik v3 implements Gateway API and is the other primary ingress
option in the programme's tech stack. It is lighter than Kong, has a simpler
configuration model, and is well-supported in the k3d/k3s ecosystem (k3s ships
Traefik by default).

**Not rejected — deferred:** Traefik is a legitimate choice and may be selected in
the Week 3 ADR once load testing and plugin requirements are evaluated against Kong.
The namespace would be `traefik` rather than `kong`, and the OPA exemption would be
updated. This ADR establishes Gateway API as the standard; the implementation choice
is Week 3's scope.

---

### Option C: Azure Application Gateway for Containers (local simulation)

**Description:** AGC is Azure's native Gateway API implementation on AKS. It could
be the target from the start — all `HTTPRoute` resources authored for AGC, validated
only on AKS.

**Rejected because:** AGC is AKS-only; there is no local equivalent for k3d. Running
every ingress test against AKS would consume the monthly budget in a week. The local-
first architecture of this programme requires a locally-runnable implementation with
AKS as the validation target, not the development environment.

---

### Option D: NGINX Gateway Fabric (as ingress-nginx successor)

**Description:** The NGINX Gateway Fabric project is an actively-maintained Gateway
API implementation from F5/NGINX, positioned as the successor to ingress-nginx for
teams already on the NGINX stack.

**Rejected because:** Adopting NGINX Gateway Fabric preserves the dependency on the
NGINX ecosystem for the benefit of familiarity, while adding the complexity of a new
project without the API gateway plugin model that Week 3 requires. Kong provides both
Gateway API ingress and API gateway functionality in a single control plane.

---

## Implementation Notes

### OPA LoadBalancer policy exemption

The Gatekeeper Constraint for LoadBalancer service restriction must include `kong`
in its permitted namespace list. If Week 3 selects Traefik, update to `traefik`.

```yaml
# policies/constraints/deny-public-loadbalancer.yaml
spec:
  parameters:
    allowedNamespaces:
      - kong        # or traefik if Week 3 ADR selects it
```

### Gateway API CRDs

Gateway API CRDs are not bundled with Kubernetes. They must be installed separately
before deploying Kong or Traefik in Gateway API mode:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

This should be a Flux-managed resource in `infrastructure/platform/` to ensure CRDs
exist before the gateway controller HelmRelease reconciles.

### Migration path for legacy `Ingress` resources

For Helm charts that generate `Ingress` resources, the migration sequence is:
1. Deploy the chart with its `Ingress` resource (accepted as technical debt)
2. Author a parallel `HTTPRoute` targeting the same backend
3. Validate traffic reaches the service via `HTTPRoute`
4. Disable the `Ingress` resource via chart values (`ingress.enabled: false`)

Do not attempt to convert `Ingress` to `HTTPRoute` automatically — the annotation
semantics do not translate 1:1 and silent behaviour changes are likely.

### Prerequisites

- [ ] Week 3 Build: Kong deployed into `kong` namespace via Flux HelmRelease
- [ ] Gateway API CRDs installed as a Flux-managed resource
- [ ] OPA LoadBalancer Constraint updated with `kong` in `allowedNamespaces`
- [ ] Week 3 ADR (`0006-api-gateway-selection.md`) produced to confirm Kong vs Traefik

### Rollback Plan

Gateway API CRDs are additive — removing the implementation (Kong/Traefik HelmRelease)
via `flux suspend` and `helm uninstall` restores the cluster to a state with no
ingress controller. Existing `HTTPRoute` resources become inert (no controller to
reconcile them) but do not cause errors. CRDs can be removed last if needed:

```bash
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

---

## Review

| Field | Value |
|-------|-------|
| **Date** | 2026-04-30 |
| **Author(s)** | Israel |
| **Reviewed by** | — |
| **Project phase / Week** | Phase 1 · Week 2 — Governance, Identity & Zero-Trust Security |
| **Next review date** | 2026-07-30 (after Week 3 build and ADR-0006 are complete) |

---

## References

- [Ingress NGINX Retirement: What You Need to Know](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [Before You Migrate: Five Surprising Ingress-NGINX Behaviors](https://kubernetes.io/blog/2026/02/27/ingress-nginx-before-you-migrate/)
- [Announcing Ingress2Gateway 1.0](https://kubernetes.io/blog/2026/03/20/ingress2gateway-1-0-release/)
- [Gateway API v1.2 release](https://kubernetes.io/blog/2025/11/06/gateway-api-v1-4/)
- [Azure Application Gateway for Containers — Gateway API support](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/overview)
- [ADR-0004 OPA Gatekeeper admission control](./0004-opa-gatekeeper-admission-control.md)
