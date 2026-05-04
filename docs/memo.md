# Migration Decision Memo
**To:** CFO, CTO, General Counsel, Compliance  
**From:** Cloud Migration Steering Committee  
**Date:** 2026-05-04  
**Re:** Contoso Financial — Cloud Migration Pattern Decision

---

## Decision

**We will lift and shift first, then optimize.** The three workloads move to AWS in their current form before any architectural refactoring begins.

---

## The Case

We have two options on the table: lift-and-shift the workloads as-is, or refactor them on the way in ("cloud-native from day one"). The CTO prefers the latter. This memo explains why the former is the right call at this stage, and what we are accepting as a consequence.

**Speed to compliance.** Our cloud contract activates data-residency controls we cannot implement on-prem. Every day we remain on-prem is a day our EU customer data lacks the residency guarantee compliance has flagged as a gap. A lift-and-shift can close that gap in weeks. A refactor-on-the-way-in timeline is measured in quarters.

**Risk is lower when the surface is smaller.** Migrating what we have means we migrate a known system. Migrating a partially refactored system means we migrate an unknown one — with new failure modes introduced mid-flight. The on-call team does not get to rehearse a refactored architecture before it handles production traffic.

**The CFO's numbers hold.** Cloud cost modeling for a lift-and-shift is predictable: we right-size the instances, set Reserved Instance coverage, and the bill is bounded. Refactoring changes utilization patterns in ways that are hard to model ahead of time. The lift-and-shift gives us 90 days of cloud cost data before we commit to architectural changes.

**The CTO's goals are not abandoned — they are sequenced.** Phase 2 (optimization) begins 90 days post-cutover. The containerization we are doing now (Challenge 4) ensures the web app is already cloud-native in its packaging. The batch job moves to AWS Batch with EventBridge scheduling, eliminating the warm-ping cron. The only workload that stays architecturally similar in Phase 1 is the reporting database, which moves to RDS with read replicas. Phase 2 refactors it further.

---

## Risks We Are Accepting

| Risk | Likelihood | Impact | Owner |
|---|---|---|---|
| Cloud cost overrun during right-sizing window | Medium | Medium | CFO — budget buffer allocated |
| Tech debt persists through Phase 1 | High (by design) | Low (isolated) | CTO — accepted in writing |
| Hardcoded on-prem IPs break post-migration | High | Medium | Engineering — remediated in Discovery |
| Shared filesystem dependency on NFS mount | High | High | Engineering — moved to S3 pre-cutover |
| Five teams query reporting DB with hardcoded creds | High | High | DBA — rotated to read-replica endpoint pre-cutover |

---

## What "Lift and Shift" Does NOT Mean

It does not mean we carry forward every bad practice. Pre-cutover, Engineering will:

1. Replace hardcoded database IPs with DNS-resolved hostnames
2. Migrate the shared NFS filesystem dependency to S3-compatible storage (MinIO locally, S3 in cloud)
3. Rotate reporting DB credentials and route teams to the RDS read-replica endpoint
4. Replace the warm-ping cron with ElastiCache Redis (no cron needed)

These are not refactors. They are prerequisites for the move to work at all.

---

## What Happens Next

- **T+0:** IaC provisioned, containers built, docker-compose stack validated locally
- **T+2 weeks:** Staging cutover — all three workloads run in AWS parallel with on-prem
- **T+4 weeks:** Production cutover — traffic switches, on-prem kept warm for 2-week rollback window
- **T+6 weeks:** On-prem decommission if no rollback triggered
- **T+90 days:** Phase 2 optimization begins (right-sizing, caching improvements, reporting DB refactor)

Legal and Compliance: please confirm data-residency requirements are satisfied by the target region selection (us-east-1 primary, us-west-2 DR) before T+2 weeks.

---

*This memo was reviewed and approved by the Cloud Migration Steering Committee. Questions: contact the migration team lead.*
