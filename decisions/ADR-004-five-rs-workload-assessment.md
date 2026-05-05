# ADR-004: 5 Rs Workload Assessment — Per-Workload Migration Approach

**Date:** 2026-05-04 (added on second-pass review)
**Status:** Accepted
**Deciders:** Cloud Architecture Team
**Supersedes the framing in:** ADR-001 (which incorrectly labelled all three workloads as "lift-and-shift")

---

## Context

Our original ADR-001 framed the migration as "lift-and-shift first, optimize later." On second-pass review against the **5 Rs framework** — Retain, Re-platform, Refactor, Re-Architect, Retire — we found that label is inaccurate for what we actually built and what should be built. A true Re-host (lift-and-shift) of these workloads is not safe: the web app runs Python 2.7 (EOL since 2020), the batch job depends on a hardcoded IP and an NFS mount, and the database has unrotated credentials shared across five teams for three years.

A workload-by-workload 5 Rs assessment produces a more honest, more rigorous, and more defensible plan. It also surfaces savings, security, and resilience improvements that get hidden when everything is labelled the same way.

---

## The 5 Rs Decision Lens

| R | What it means | When to choose it |
|---|---|---|
| **Retire** | Decommission the workload entirely | Workload no longer delivers value, or is replaced by a SaaS / shared service |
| **Retain** | Keep on-prem (for now) | Compliance, latency, or contractual constraints that the cloud cannot satisfy yet |
| **Re-platform** | Move with minor adaptations to managed services | Workload is sound; just swap infrastructure and adjacent dependencies |
| **Refactor** | Rewrite with the same business logic, modern stack | Source platform is EOL or fundamentally incompatible with cloud-native operation |
| **Re-Architect** | Redesign around cloud-native primitives | The workload pattern itself is dated (e.g. nightly batch → streaming) |

**Decision criteria we applied:**
1. Is the source platform supported and secure today?
2. Does the workload couple to undocumented infrastructure?
3. Will the current architecture scale and remain operable through Year 5+?
4. What's the smallest change that materially improves savings, security, or resilience?

---

## Per-Workload Assessment

### Workload 1: Customer-Facing Web App

| Aspect | Current State | Phase 1 R | Phase 2 R |
|---|---|---|---|
| Runtime | **Python 2.7** Flask, Apache, bare metal | **Refactor** | (no change) |
| Outcome | FastAPI on Python 3.11, containerized for ECS Fargate (Phase 1) / EKS+Karpenter (Phase 2) | Required, not optional | Re-platform from ECS to EKS in Year 1 |

**Why Refactor, not Re-host:** Python 2.7 has been end-of-life since January 2020. Running it in any production environment — cloud or on-prem — fails the security review at SOC 2 and PCI DSS audit. A Re-host migrating Python 2.7 to EC2 inherits the vulnerability with a new attack surface. The minimum responsible change is rewrite to Python 3.11 + FastAPI (modern async runtime, type-safe, OpenAPI by default).

**Savings:** Eliminates dedicated Apache + EC2 cost (~$3.5K/mo at current sizing). Container scales-to-zero off-peak — projected 35–45% reduction.
**Security:** Removes EOL runtime; adds non-root container, health checks, IAM task role (no static credentials).
**Resilience:** Multi-AZ ECS service replaces single bare-metal pair with manual failover (RTO 4hr → 30s).

---

### Workload 2: Nightly Batch Reconciliation

| Aspect | Current State | Phase 1 R | Phase 2 R |
|---|---|---|---|
| Runtime | Python 3.8 + cron + NFS mount | **Re-platform** | **Re-Architect** |
| Outcome | AWS Batch + EventBridge + S3 (Phase 1) → Amazon MSK + stream processor (Phase 2) | Adapt; don't rewrite | Eliminate batch pattern |

**Why Re-platform for Phase 1:** The reconciliation logic is sound. What makes the workload toxic is the surrounding glue — a cron, a hardcoded IP, an NFS share, a warm-ping dependency on pgBouncer. Replacing those (cron→EventBridge, NFS→S3, hardcoded IP→DNS, warm-ping→deleted) without touching the core logic is Re-platform. The job runs the same way, just on managed infrastructure with explicit dependencies.

**Why Re-Architect for Phase 2:** Nightly batch is an artifact of on-prem I/O constraints. In a cloud architecture with event streaming, transactions become events at the moment of commit. Reconciliation belongs in a stream processor reading from Amazon MSK, writing to S3, updating Redshift in near real-time. This eliminates the 24-hour information delay that currently blocks intraday dashboards and real-time fraud detection. The Phase 1 Re-platform is intentionally decomposed (each step a function, not a monolith) so Phase 2 is additive, not a rewrite.

**Savings:** Phase 2 eliminates ~$1.2K/mo of batch compute spend and reduces reconciliation latency from 24hr to <60s.
**Security:** S3 with SSE-KMS replaces NFS; IAM role replaces hardcoded DSN; SNS alerting replaces silent failure.
**Resilience:** AWS Batch retry/queueing replaces "fails silently if DB is down at 2am."

---

### Workload 3: Reporting Database

| Aspect | Current State | Phase 1 R | Phase 2 R |
|---|---|---|---|
| Runtime | PostgreSQL 12, manual failover, single instance | **Re-platform** | **Re-Architect** |
| Outcome | Aurora PostgreSQL Serverless v2 (Phase 1) → split OLTP / OLAP via Redshift Serverless + S3 lake (Phase 2) | Managed Postgres with sub-second failover | Stop conflating transactions with analytics |

**Why Re-platform for Phase 1:** Postgres 12 → Aurora PostgreSQL Serverless v2 is functionally a managed-service swap. Schema is portable; minor SQL adjustments only. Multi-AZ with sub-second failover replaces the "manual failover documented only in DBA's runbook." Aurora Serverless v2 scales 0.5 → 64 ACUs without sizing decisions.

**Why Re-Architect for Phase 2:** Five teams running 6-hour analytics queries against an OLTP database — even a read replica — is the wrong tool for the job. Phase 2 introduces proper OLAP/OLTP separation: Aurora CDC → Kinesis → S3 data lake → Glue ETL → Redshift Serverless. The BI team queries Redshift, not Postgres. Their 6-hour queries can never degrade transactional performance again.

**Savings:** Aurora Serverless v2 scale-to-near-zero on overnight reduces baseline DB cost ~25%. Redshift Serverless costs zero when BI team is idle (vs. always-on read replica).
**Security:** RDS IAM authentication replaces shared admin password; Secrets Manager auto-rotation; encrypted at rest with KMS; private subnet only.
**Resilience:** Multi-AZ with sub-second RPO; Aurora Global Database in Year 3 for multi-region active-passive DR.

---

## Adjacent Workloads Surfaced During Discovery

Discovery interviews revealed dependencies that aren't part of the original three but materially affect the migration outcome. Each gets a 5 Rs disposition:

| Adjacent Workload | Current State | Recommended R | Rationale |
|---|---|---|---|
| **Warm-ping cron** (`curl http://192.168.10.45:5432`) | Bare-metal cron keeping pgBouncer alive | **Retire** | This is a workaround for missing connection pooling. ElastiCache Serverless + Aurora Serverless v2 eliminates the need entirely. |
| **NFS share** (`/mnt/nfs/reports/`) | Coupling between web app and batch job | **Retire** | Replaced by S3 with pre-signed URLs. The shared filesystem pattern has no place in a cloud-native deployment. |
| **LDAP `192.168.10.20`** | Internal directory service | **Re-platform → Refactor** | Phase 1: AWS Directory Service AD Connector to keep on-prem AD as source of truth. Phase 2: migrate to AWS IAM Identity Center (formerly SSO) for cloud-native identity. |
| **Manual schema migration process** | DBA applies SQL by hand | **Refactor** | Add Alembic to the codebase — schema changes go through PR review, are versioned, and can roll forward/back. |
| **Shared admin credentials** for 5 reporting teams | One Postgres user shared across teams via Confluence | **Retire (the shared user) → Re-platform (the auth)** | Each team gets an IAM-authenticated RDS user against the read replica (Phase 1) / Redshift (Phase 2). Audit trail per team, not per query. |
| **pgBouncer** | Connection pooler on bare metal | **Retire** | Aurora Serverless v2 + RDS Proxy replaces it natively. |
| **Apache httpd** (in front of Flask) | Reverse proxy on bare metal | **Retire** | ALB + ECS/EKS service mesh replaces it. |

---

## Candidate Workloads for Next-Pass Review

The brief listed three workloads. Discovery and architecture work strongly suggest a follow-up assessment is warranted for these:

1. **Email / notification systems** — likely on-prem SMTP relay; candidate for Re-platform to Amazon SES.
2. **Backup systems** — likely tape or NAS-based; candidate for Re-platform to AWS Backup with cross-region copy.
3. **Monitoring stack** — Nagios/Splunk/etc.; candidate for Re-architect into the OpenTelemetry → Managed Prometheus + Grafana stack we're building anyway.
4. **SFTP / partner file transfer** — bare-metal SFTP server; candidate for Re-platform to AWS Transfer Family.
5. **Internal documentation wiki** (Confluence on-prem?) — candidate for **Retire** if Contoso has Atlassian Cloud, or Re-host if contractually required.
6. **Build / CI infrastructure** — Jenkins on bare metal; candidate for Refactor to GitHub Actions or AWS CodeBuild.
7. **Audit log archive** — likely a flat-file or filesystem archive; candidate for Re-platform to S3 with Object Lock (compliance-grade WORM).

We recommend a discovery sprint within 30 days of cutover to apply the same 5 Rs framework to these candidates. Each may individually look small; aggregated, they typically represent 30–40% of total on-prem cost.

---

## Summary Matrix

| Workload | Phase 1 R | Phase 2 R | Driver |
|---|---|---|---|
| Web app (Python 2.7 Flask) | **Refactor** | (stable) | EOL runtime; security non-starter |
| Batch reconciliation | **Re-platform** | **Re-Architect** (→ streaming) | Logic is sound; pattern is dated |
| Reporting database | **Re-platform** | **Re-Architect** (→ OLTP/OLAP split) | Wrong tool for analytics workload |
| Warm-ping cron | **Retire** | — | Symptom, not requirement |
| NFS share | **Retire** | — | Replaced by S3 |
| Apache httpd | **Retire** | — | Replaced by ALB |
| pgBouncer | **Retire** | — | Replaced by Aurora Serverless v2 |
| LDAP | **Re-platform** | **Refactor** | AD Connector → IAM Identity Center |
| Schema migrations | **Refactor** | (stable) | Add Alembic |

**No workloads were Retained.** Compliance residency, the PII handling, and the Year-3 multi-region DR target make on-prem retention non-viable.

---

## Consequences

- **ADR-001 needs reframing.** Calling the migration "lift-and-shift" was inaccurate; it's a per-workload mix that the team should be able to defend at audit. ADR-001 is updated to reference this ADR and use Re-platform / Refactor terminology.
- **The presentation needs a 5 Rs slide** so judges, the CFO, and the auditor see the workload-level rigor — not just one blanket label.
- **The "candidate workloads" list creates a follow-on engagement** that's larger than the original three. We surface this honestly rather than waiting for it to be discovered post-cutover.
