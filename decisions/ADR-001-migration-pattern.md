# ADR-001: Migration Pattern — Lift-and-Shift First, Optimize in Phase 2

**Date:** 2026-05-04  
**Status:** Accepted  
**Deciders:** Cloud Migration Steering Committee

---

## Context

Contoso Financial must migrate three on-prem workloads to AWS. Two migration patterns are viable:

- **Option A: Lift-and-shift** — move workloads as-is to cloud-equivalent services, defer architectural refactoring to Phase 2
- **Option B: Refactor on the way in** — modernize architecture (microservices, managed services, cloud-native patterns) during the migration itself

The CFO wants predictable cost and timeline. The CTO wants a cloud-native result. Compliance requires data residency controls that only the cloud contract provides.

---

## Decision

**Adopt Option A (lift-and-shift) for Phase 1.** Phase 2 optimization begins 90 days post-cutover.

---

## Rationale

| Factor | Lift-and-shift | Refactor-on-the-way-in |
|---|---|---|
| Time to close compliance gap | 2–4 weeks | 3–6 months |
| Migration risk | Low (known system) | High (new system + migration simultaneously) |
| Cost predictability | High | Low |
| CTO's cloud-native goal | Deferred 90 days | Achieved immediately |
| On-call readiness | High (familiar system) | Low (new architecture, new failure modes) |

The compliance gap is the forcing function. Data residency controls require the workloads to be in AWS. Every week on-prem is a risk. A refactor adds 10–20 weeks to close the same gap.

Pre-cutover, Engineering will remediate the four blockers identified in discovery (hardcoded IPs, NFS dependency, credential sprawl, warm-ping cron). These are not refactors — they are prerequisites that would be required under either option.

---

## Consequences

**Accepted:**
- Tech debt from Flask (Python 2.7) and manual Postgres failover persists through Phase 1
- CTO dissatisfaction with interim state — mitigated by Phase 2 commitment in writing
- Cloud cost may be higher during right-sizing window (first 30–60 days)

**Not accepted as permanent:**
- Hardcoded IPs, shared NFS mount, credential sprawl — all resolved pre-cutover (see discovery blockers)

**Phase 2 scope (not this ADR):**
- Flask → FastAPI rewrite
- Reporting DB: Aurora Serverless + RDS Proxy
- Batch job: Step Functions for orchestration and retry
- BI workload: Dedicated analytics cluster or Redshift
