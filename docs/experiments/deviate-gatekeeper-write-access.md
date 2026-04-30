## DEVIATE — Gatekeeper Write Access on platform-admin

**Change:** Restricted `constraints.gatekeeper.sh` verbs in `platform-admin` 
ClusterRole from `["*"]` to `["get","list","watch"]`. Deployed via Flux. 
Validated using `kubectl --as=system:serviceaccount:deviate-test:platform-admin-sa`.

**What the system revealed:** The restriction enforced correctly — patch operations 
on `requireresourcelimits` returned a precise 403 identifying the API group, 
resource, verb, and identity. The mechanism works. The problem is what you've 
removed: the only out-of-band recovery path for a specific deadlock. If a 
misconfigured constraint or an overly broad `failurePolicy: Fail` blocks Flux's 
own reconciliation loop, the Platform Engineer cannot patch or delete the offending 
constraint without `cluster-admin` break-glass escalation. Flux cannot fix the 
thing that is preventing Flux from running. This is not a theoretical edge case — 
it is the documented failure mode for any cluster running Gatekeeper with 
`failurePolicy: Fail`.

**The category error:** Applying least privilege to break-glass permissions 
conflates two distinct access patterns. Least privilege governs steady-state 
operations — the permissions a persona exercises daily. Break-glass permissions 
exist outside steady-state, for the specific scenarios where the system enforcing 
normal access control is itself broken. Removing Gatekeeper write access from 
`platform-admin` satisfies the letter of least privilege while eliminating the 
recovery path it was designed to protect. The right response to "this feels 
over-privileged" is not removal — it is audit. Every write operation against 
`constraints.gatekeeper.sh` by `platform-admin` should generate an audit log 
entry. The permission stays; its use becomes visible.

**Decision:** Reverted to `verbs: ["*"]` on Gatekeeper API groups. Audit logging 
for `platform-admin` Gatekeeper writes is a deferred gap — target Week 8 when 
OpenTelemetry and audit pipeline work arrives.