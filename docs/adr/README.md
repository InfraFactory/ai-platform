# Architecture Decision Records

This directory contains the Architecture Decision Records (ADRs) for the `ai-platform` project.

## What is an ADR?

An ADR is a short document that captures an important architectural decision: the context that forced it, the decision itself, and the consequences of making it. ADRs are written once and treated as immutable history — if a decision changes, a new ADR is written that supersedes the old one rather than editing it in place.

## Lifecycle

```
Proposed → Accepted → Deprecated
                    ↘ Superseded by ADR-XXXX
```

| Status | Meaning |
|--------|---------|
| **Proposed** | Under discussion, not yet binding |
| **Accepted** | Decision is active and in effect |
| **Deprecated** | No longer relevant but not replaced |
| **Superseded** | Replaced by a newer ADR (link provided) |

## Numbering & Naming

Files follow the pattern `NNNN-short-hyphenated-title.md`, where `NNNN` is a zero-padded sequence number.

```
0001-hub-spoke-vs-vwan.md
0002-use-flux-for-cluster-bootstrap.md
0003-opa-gatekeeper-for-policy-enforcement.md
```

Numbers are never reused. Gaps are acceptable.

## How to Write a New ADR

1. Copy `template.md` to a new file with the next sequence number.
2. Fill in every section — do not delete sections you think are empty; use "N/A" if truly not applicable.
3. Set status to **Proposed** and open a PR for review.
4. On merge, update status to **Accepted** in the same PR.
5. If the decision supersedes an earlier ADR, update the old file's status to `Superseded by ADR-XXXX`.

## When to Write an ADR

Write an ADR whenever a decision:

- Is **hard to reverse** (infrastructure topology, GitOps tool choice, identity model)
- Affects **multiple components or teams**
- Involves a **significant trade-off** between options
- Will likely be **questioned later** ("why did we do it this way?")

You do not need an ADR for implementation details, minor config choices, or decisions that are trivially reversible.

## Index

| # | Title | Status | Week |
|---|-------|--------|------|
| [0001](./0001-hub-spoke-vs-vwan.md) | Hub-Spoke vs vWAN | Proposed | 1 |

> Update this table whenever a new ADR is merged.

## References

- [Documenting Architecture Decisions — Michael Nygard (2011)](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
- [ADR GitHub Organisation](https://adr.github.io/)
- [MADR — Markdown Architectural Decision Records](https://adr.github.io/madr/)
