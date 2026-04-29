# ADR-001 — Hub-spoke over Virtual WAN

## Status

Accepted

## Context

The `alz-mgmt` deployment manages fewer than 10 spokes in a single-region (Australia East) learning environment. Connectivity requirements are hub-centric: spokes connect outbound via the hub firewall, and any spoke-to-spoke traffic within the region hairpins through the hub. This is acceptable at the current scale and adds no meaningful latency penalty.

The deployment serves a dual purpose: it is a functional learning environment and a reference architecture for future production recommendations. The platform engineering function is owned by a single engineer. Monthly Azure spend is constrained to A$100.

The network topology decision was made at initial deployment using the AVM Terraform accelerator, which supports both hub-spoke and Virtual WAN via separate configuration paths. This ADR documents the reasoning behind the hub-spoke selection so that the decision is owned explicitly rather than inherited from accelerator defaults.

## Decision

Hub-spoke virtual network topology is chosen over Azure Virtual WAN.

The primary reason is scale mismatch. vWAN's core value proposition is the elimination of routing operational burden at scale: managed hubs, automatic route propagation across regions, and a global transit mesh for any-to-any cross-region connectivity without hairpinning. At fewer than 10 spokes in a single region, none of these capabilities address a problem this deployment has. Adding vWAN here would introduce managed-platform abstraction without solving any current operational concern.

The secondary reason is learning value. Hub-spoke requires explicit reasoning about user-defined routes, VNet peering configuration, and firewall traversal paths. This exposure builds the architectural intuition necessary to evaluate and advise on both topologies at production scale. A managed routing layer would obscure exactly the mechanics that matter most to understand deeply. The programme's goal — developing the higher-order reasoning of a systems architect — is better served by owning the control plane than by delegating it.

Cost reinforces the decision but does not make it. Hub-spoke is architecturally correct for this deployment context independent of budget. The avoided cost (~A$400–600/month for vWAN managed hubs and associated gateway SKUs) is a supporting factor that confirms the decision, not the reason for it.

## Alternatives considered

**Azure Virtual WAN** was evaluated and rejected for this deployment at current scale. vWAN is the appropriate choice when one or more of the following conditions holds:

- Spoke count exceeds 20–30 and UDR management becomes an ongoing operational burden requiring dedicated automation or engineering time
- Any-to-any cross-region connectivity is required and hub hairpin latency is architecturally unacceptable for the workload
- The platform team lacks capacity to own route management manually and needs the control plane abstracted to the platform

None of these conditions apply to this deployment. vWAN is not rejected as a wrong choice in general — it is rejected as the wrong choice for this specific context and scale.

## Consequences

**Accepted trade-offs:**

This decision retains full ownership of the routing control plane. UDR management — ensuring every spoke routes default traffic through the hub firewall, and that new spokes are correctly configured on addition — remains a manual or scripted concern. At current spoke count this is low-burden. As spoke count grows, this becomes the first operational pressure point.

Spoke-to-spoke traffic within Australia East hairpins through the hub firewall. This is a deliberate design choice, not a limitation — it ensures all east-west traffic is inspected. The consequence is that firewall throughput becomes a constraint if spoke-to-spoke traffic volume increases significantly.

Cross-region spoke-to-spoke connectivity, if required in future, would hairpin through both regional hubs, doubling firewall traversal and adding latency. This is acceptable for the current single-region deployment but would be a meaningful architectural cost at multi-region scale.

**Migration path:**

The AVM Terraform accelerator supports both hub-spoke (`main.connectivity.hub.and.spoke.virtual.network.tf`) and Virtual WAN (`main.connectivity.virtual.wan.tf`) via separate configuration paths. Migration from hub-spoke to vWAN is a Terraform configuration change, not an infrastructure rebuild from scratch. The management group hierarchy, policy assignments, and management resources are topology-independent and would not be affected by a migration.

**Conditions for revisiting this decision:**

- Spoke count approaches 20, or a second active region is added with east-west traffic requirements between regions
- UDR management time exceeds approximately 20% of platform engineering capacity on an ongoing basis
- A workload is onboarded that requires cross-region latency that hub hairpin cannot meet
- The programme expands to require vWAN-specific patterns (e.g. Secure Virtual Hub with Azure Firewall Manager) as part of a client engagement

At any of these trigger points, the operational cost of maintaining hub-spoke will likely exceed the licence cost of vWAN, and migration should be planned with the AVM accelerator's Virtual WAN path as the target configuration.