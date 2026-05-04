# Discovery: Contoso Financial — Current State

*Generated via stakeholder roleplay and config analysis. Each hidden dependency is flagged with its migration blocker status.*

---

## Workload 1: Customer-Facing Web App

**Runtime:** Python 2.7 Flask, Apache httpd, bare metal (2x Dell R720, active-passive)  
**Traffic:** ~800 req/min peak, ~120 req/min average  
**Port:** 80/443 external, 8080 internal

### Dependencies

| Dependency | Type | Discovery Method | Migration Blocker? |
|---|---|---|---|
| `DB_HOST=192.168.10.45` in `app.config` | Hardcoded on-prem IP | Config file grep | **YES** — replace with DNS / env var |
| `/mnt/nfs/reports/` — shared NFS mount | Shared filesystem | SRE interview | **YES** — move to S3 |
| `redis://192.168.10.80:6379` in session config | Hardcoded IP | Config file grep | **YES** — replace with env var |
| LDAP auth to `ldap://192.168.10.20` | Internal directory | App code review | Medium — plan AD connector or migrate users |

### Stakeholder Interview Notes (SRE — "Alex")

> "The app hasn't been touched in 18 months. The NFS mount is where the batch job drops its reconciliation PDFs and the web app serves them. Nobody documented it. I found out when I tried to restart one of the web servers and the PDF download endpoint 404'd for an hour."

> "There's also a cron on the app server that runs `curl http://192.168.10.45:5432` every 5 minutes. We think it's keeping the Postgres connection warm in pgBouncer but honestly nobody is sure. It was there when I joined."

**Action:** Remove warm-ping cron. Replace with ElastiCache Redis for session state; app connects to connection pool endpoint. NFS → S3 pre-migration.

---

## Workload 2: Nightly Batch Reconciliation Job

**Runtime:** Python 3.8, cron on dedicated batch server (`batch01.contoso.local`)  
**Schedule:** `0 2 * * *` (2am local time)  
**Output:** CSV and PDF files written to `/mnt/nfs/reports/` (shared with web app)

### Dependencies

| Dependency | Type | Discovery Method | Migration Blocker? |
|---|---|---|---|
| Reads from `reporting_db` via hardcoded `psycopg2` DSN | Hardcoded DSN | Code review | **YES** — parameterize via env var |
| Writes output to `/mnt/nfs/reports/` | Shared filesystem (NFS) | SRE interview | **YES** — move to S3 |
| `curl http://192.168.10.45:5432` warm-ping cron | Hardcoded IP + side effect | SRE interview | **YES** — eliminate entirely |
| Reads prior-day output from NFS to compute delta | Cross-run state dependency | Batch job owner interview | Medium — idempotency needed |
| No retry logic — fails silently if DB is down at 2am | Missing resilience | Code review | Medium — add retry before cloud cutover |

### Stakeholder Interview Notes (Batch Job Owner — "Maria")

> "The job writes its output files to the shared drive and the web app picks them up. If the cron doesn't run, nobody knows until someone checks the download portal in the morning. We have no alerting."

> "The job reads its own prior-day output to compute the day-over-day delta. That file lives on the NFS share too. If it's missing, the job crashes with a FileNotFoundError and the reconciliation for the day is just... missing."

**Action:** Batch moves to AWS Batch with EventBridge trigger. Output written to S3 (`s3://contoso-reports/reconciliation/YYYY-MM-DD/`). Job reads prior day from S3 (same bucket, prior date prefix). SNS alert on job failure.

---

## Workload 3: Reporting Database

**Runtime:** PostgreSQL 12.8, bare metal (`db01.contoso.local`, `db02.contoso.local` — manual failover)  
**Size:** 420 GB data, 1.2 TB with WAL archives  
**Access:** 5 teams (Finance, Risk, Compliance, Ops, BI) query directly

### Dependencies

| Dependency | Type | Discovery Method | Migration Blocker? |
|---|---|---|---|
| 5 teams hardcoded `postgres://user:password@192.168.10.45/reporting` | Hardcoded IPs + credentials | DBA interview | **YES** — credential rotation + DNS |
| No connection pooling — max_connections frequently hit | Missing infra | DBA interview | Medium — add RDS Proxy post-migration |
| Manual failover documented only in DBA runbook | Ops gap | DBA interview | Medium — RDS multi-AZ eliminates this |
| BI team runs 6-hour analytics queries during business hours | Workload contention | DBA interview | **YES** — route BI to read replica |
| Schema migrations done by hand — no migration tool | Ops gap | DBA interview | Medium — add Alembic pre-migration |

### Stakeholder Interview Notes (DBA — "James")

> "We've had the same Postgres admin user credentials shared across all five teams for three years. Every time someone leaves, we're supposed to rotate them, but it disrupts the BI queries and everyone pushes back. The credentials are in spreadsheets, Confluence, and about four people's local config files."

> "The BI team's big queries lock up the primary sometimes. We have a read replica but nobody actually uses it because it's not in the connection strings."

**Cross-workload coupling discovered:** The web app's warm-ping cron and the batch job both connect to the same Postgres primary (`192.168.10.45`). Any migration that changes the DB endpoint requires updating **both** workloads simultaneously — a single-workload migration would leave the other pointing at a dead IP.

---

## Summary: Hidden Dependencies That Must Be Resolved Pre-Cutover

1. **Hardcoded IP `192.168.10.45`** appears in web app config, batch DSN, and warm-ping cron — all three workloads must update in the same cutover window
2. **Shared NFS mount `/mnt/nfs/reports/`** couples web app and batch job — must migrate to S3 before either workload can move independently
3. **Warm-ping cron** (`curl http://192.168.10.45:5432`) — undocumented dependency keeping pgBouncer alive; eliminate by moving to ElastiCache for session state
4. **Credential sprawl** in reporting DB — all five teams must rotate to new RDS read-replica endpoint in a coordinated change window

These findings directly shape the architecture choices in [ADR-002](../decisions/ADR-002-target-cloud-services.md): the decision to use ElastiCache Redis (eliminates the warm-ping), RDS read replicas (routes BI team away from primary), and S3 for report storage (decouples the two workloads that share NFS).
