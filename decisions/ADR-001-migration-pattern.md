# ADR-001: Migration Pattern — Per-Workload 5 Rs (Not Blanket Lift-and-Shift)

**Date:** 2026-05-04 (revised)
**Status:** Accepted
**Deciders:** Cloud Migration Steering Committee
**Related:** ADR-004 (5 Rs workload assessment) — read first for the per-workload analysis

---

## Context

Two migration framings were debated:

- **Option A: Blanket "lift-and-shift first, optimize later"** — single label applied to every workload, defer optimization to Phase 2
- **Option B: Per-workload 5 Rs assessment** (Retain, Re-platform, Refactor, Re-Architect, Retire) — each workload gets the right disposition based on its specific state, risk, and 15-year trajectory

The CFO wants predictable cost and timeline. The CTO wants a defensible architecture. Compliance requires data residency controls that only the cloud contract provides. The DBA wants the manual failover runbook gone.

We initially adopted Option A. On a second-pass review, we found Option A was inaccurate: a true Re-host (lift-and-shift) of these workloads was not safely possible. The web app runs Python 2.7 (EOL). The batch job has a hardcoded IP and an NFS dependency. The database has shared credentials across five teams. None of those can be lifted as-is.

---

## Decision

**Adopt Option B: per-workload 5 Rs assessment, documented in [ADR-004](ADR-004-five-rs-workload-assessment.md).**

The Phase 1 dispositions are:

| Workload | Phase 1 Disposition |
|---|---|
| Customer-facing web app | **Refactor** (Python 2.7 → 3.11 + FastAPI; EOL forces this) |
| Batch reconciliation | **Re-platform** (cron→EventBridge, NFS→S3, IP→DNS; logic unchanged) |
| Reporting database | **Re-platform** (Postgres 12 → Aurora Serverless v2) |
| Warm-ping cron, NFS, Apache, pgBouncer, shared admin user | **Retire** |

Phase 2 (within 18 months) introduces Re-Architect dispositions for the batch job (→ streaming) and the database (→ OLTP/OLAP split with Redshift).

---

## Rationale

| Factor | Blanket lift-and-shift | Per-workload 5 Rs |
|---|---|---|
| Honesty about what we're shipping | Low (label doesn't match the work) | High |
| Time to close compliance gap | 2–4 weeks | 2–4 weeks (same; the EOL runtime is the constraint, not the label) |
| Audit defensibility | Weak | Strong (each disposition has a documented driver) |
| Identifies retire candidates | No | Yes (six workloads explicitly retired) |
| Surfaces savings sources | Generic | Per-workload (~$4.7K/mo aggregate Phase 1, ~$2K/mo additional in Phase 2) |
| Aligns with 15-year horizon | No | Yes (Phase 2 R-disposition is named, not deferred to a vague "later") |

The compliance gap is the forcing function for *moving*, but not for the choice between lift-and-shift and per-workload R-classification. That choice is about whether we can defend our work to the auditor, the CFO, and the on-call team — and whether we can recover savings that lift-and-shift hides.

---

## Consequences

**Accepted:**
- Refactoring the web app (Python 2.7 → 3.11) adds 1–2 weeks of engineering work vs. a hypothetical Re-host
- The 5 Rs analysis adds documentation overhead vs. a single-line "lift-and-shift" plan
- Phase 2 commitments are now explicit (and therefore enforceable) rather than vague

**Avoided:**
- Carrying Python 2.7 into AWS — a non-starter at the next SOC 2 audit
- Treating the warm-ping cron and NFS mount as features to migrate (they were bugs to retire)
- Hiding tech debt behind a "we'll optimize later" label that gets quietly forgotten

**Phase 2 commitments (in writing, owners assigned):**
- Web app: ECS Fargate → EKS + Karpenter (Re-platform within 12 months) — owner: Platform team
- Batch: AWS Batch → Amazon MSK + stream processor (Re-Architect within 18 months) — owner: Data Eng
- Reporting: Aurora read replica → Redshift Serverless + S3 lake (Re-Architect within 18 months) — owner: Data Eng
- LDAP: AD Connector → IAM Identity Center (Refactor within 24 months) — owner: Security

---

## What This ADR Replaces

The previous version of this ADR adopted "lift-and-shift first, optimize later" as a blanket label. That framing is retained nowhere in the current architecture and should not be cited externally. ADR-004 is the authoritative source for per-workload disposition.
