# Team EAAS_Cloud_Migration

## Participants
- Raymond Clarance (Architect / Platform)
- Venkat Pal (Developer)
- Srinath Jagannathan (PM / Quality)
- Saurabh Aggarwal (Developer / Infrastructure)

## Scenario
Scenario 2: Cloud Migration — "The Lift, the Shift, and the 4am Call"

## What We Built

We migrated three Contoso Financial workloads to AWS using a **per-workload 5 Rs disposition** (Refactor, Re-platform, Re-Architect, Retire) — not a blanket lift-and-shift. The blanket framing was inaccurate: Python 2.7 cannot be safely re-hosted (EOL since 2020), the warm-ping cron is a bug not a feature, and the NFS mount is a coupling not a dependency.

The repo contains production-ready artifacts that run locally with cloud-equivalent architecture: Docker Compose maps MinIO → S3, Postgres → RDS, Redis → ElastiCache. A multi-stage Dockerfile produces an image deployable to ECS Fargate (Phase 1) or EKS (Phase 2) with a config swap. Terraform IaC covers the Phase 1 AWS target state. A PreToolUse Claude Code hook deterministically blocks any plaintext secret from being written into `.tf` files. Four ADRs capture the migration approach, service selection, the hook-vs-prompt enforcement decision, and the per-workload 5 Rs assessment. **Three runbooks** translate the architecture for three different reading minds: Legal/Compliance, the CTO's office, and Ops at 4am.

## The 5 Rs at a glance

| Workload | Phase 1 R | Phase 2 R | Driver |
|---|---|---|---|
| Web app (Python 2.7 Flask, bare metal) | **Refactor** | (stable) | Python 2.7 is EOL — re-host fails security review |
| Batch reconciliation (cron + NFS) | **Re-platform** | **Re-Architect** (→ MSK streaming) | Phase 1: cron→EventBridge, NFS→S3. Phase 2: kill batch pattern entirely |
| Reporting database (Postgres 12, manual failover) | **Re-platform** | **Re-Architect** (→ OLTP/OLAP split) | Phase 1: Aurora Serverless v2. Phase 2: Redshift Serverless for BI |
| LDAP (192.168.10.20) | **Re-platform** (AD Connector) | **Refactor** (→ IAM Identity Center) | Cloud-native identity in Phase 2 |
| Warm-ping cron, NFS, Apache, pgBouncer, shared admin user | **Retire** (×5) | — | Bugs masquerading as dependencies |

Six adjacent components retired. **No workloads were retained on-prem.** Full analysis: [`decisions/ADR-004-five-rs-workload-assessment.md`](decisions/ADR-004-five-rs-workload-assessment.md).

## Challenges Attempted

| # | Challenge | Status | Notes |
|---|---|---|---|
| 1 | The Memo | done | [`docs/memo.md`](docs/memo.md) — one page, no hedging, risks owned |
| 2 | The Discovery | done | [`docs/discovery.md`](docs/discovery.md) — 4 hidden deps surfaced via stakeholder roleplay |
| 3 | The Options | done | [`decisions/ADR-001`](decisions/ADR-001-migration-pattern.md) (5 Rs pattern) + [`ADR-002`](decisions/ADR-002-target-cloud-services.md) (services scored on 15-year criteria) |
| 4 | The Container | done | FastAPI web app, multi-stage Dockerfile, non-root user, health check |
| 5 | The Foundation | done | Terraform modules (ECS, RDS, ElastiCache, S3) + docker-compose.yml + PreToolUse hook |
| 6 | The Proof | done | Smoke, contract, and integrity tests; each integrity test traces to a named Discovery finding |
| + | ADR-003 (Hook vs Prompt) | done | [`decisions/ADR-003`](decisions/ADR-003-secrets-hook-vs-prompt.md) — cert domain artifact |
| + | ADR-004 (5 Rs assessment) | done | [`decisions/ADR-004`](decisions/ADR-004-five-rs-workload-assessment.md) — per-workload disposition |
| + | Three audience runbooks | done | [`runbooks/`](runbooks/) — Legal, CTO Office, Ops (4am) |
| 7 | The Scorecard | skipped | Time constraint |
| 8 | The Undo | partial | Rollback procedures in [`runbooks/ops-runbook.md`](runbooks/ops-runbook.md) section 4 |
| 9 | The Survey | skipped | Time constraint — would automate the manual stakeholder roleplay |

## Three Runbooks for Three Audiences

The hackathon brief said: *"The auditor will read your IaC, the CTO will read your ADRs, and ops will run your runbook at 4am. Design for all three readers."*

We did:

- **[`runbooks/legal-compliance-runbook.md`](runbooks/legal-compliance-runbook.md)** — for General Counsel, Compliance, and external auditors. Anchored in evidence: SOC 2 / PCI / GLBA / GDPR scope, control mapping with evidence locations, audit trail, vendor risk, sign-off checklist.

- **[`runbooks/cto-office-runbook.md`](runbooks/cto-office-runbook.md)** — for the CTO and architecture leadership. ADR index, top-10 risk register with trip-wires, Phase 2 commitment table with named owners and deadlines, 3-year TCO, tech radar, escalation chain, "what worries me at 3am."

- **[`runbooks/ops-runbook.md`](runbooks/ops-runbook.md)** — the 4am runbook for SRE on-call. Cutover sequence T-7d through T+14d, exact rollback commands per workload, severity matrix with paging order, triage decision tree, five common failure mode playbooks.

Same architecture, three different reading minds, three different documents.

## Key Decisions

1. **Per-workload 5 Rs, not blanket lift-and-shift** — Python 2.7 cannot be re-hosted safely. Each workload gets the right disposition. Full rationale: [`ADR-001`](decisions/ADR-001-migration-pattern.md).

2. **Phase 1 ships ECS + RDS; Phase 2 target is EKS + Aurora + Redshift Serverless** — we deliberately did *not* prematurely upgrade the IaC. Phase 1 runs today; Phase 2 is reversible at known cost. Phase 2 commitments are in [`cto-office-runbook.md`](runbooks/cto-office-runbook.md) section 4 with named owners. Service selections: [`ADR-002`](decisions/ADR-002-target-cloud-services.md).

3. **PreToolUse hook for secrets, not just a prompt** — hardcoded secrets in IaC have no legitimate exception. The hook blocks unconditionally; the prompt shapes outputs upstream. [`ADR-003`](decisions/ADR-003-secrets-hook-vs-prompt.md).

4. **15-year horizon framed as reversibility, not prediction** — nobody predicts 2041. We made each decision reversible at a known cost. EKS → ECS is 4 weeks; Aurora → RDS is 2 weeks. *That* is what 15-year planning actually looks like.

## How to Run It

Requires: Docker, Docker Compose, Python 3.11+, `uv`

```bash
# Start local cloud-equivalent stack (MinIO, Postgres, Redis, web app)
docker compose up -d

# Verify
curl http://localhost:8000/health         # → {"status":"ok",...}
open http://localhost:9001                 # MinIO console
open http://localhost:8000/docs            # FastAPI auto-docs

# Run full validation suite
cd tests && uv run pytest -v

# Verify Terraform (no live cloud needed)
cd infra && terraform init && terraform validate

# Stop the stack
docker compose down
```

## Proof of Life

Captured at submission time:

- **PreToolUse hook regex:** 7/7 test cases pass (3 BLOCK, 4 PASS) — see [`presentation.html`](presentation.html) slide 6
- **Python source compilation:** 7/7 files compile with no errors (`python3 -m py_compile`)
- **Terraform brace balance:** 7/7 files balanced (sanity check; full `terraform validate` requires Terraform CLI installed)
- **Docker Compose:** not run in this validation environment (Docker daemon not available in sandbox). Compose file is syntactically valid; topology mirrors architecture diagram. Confidence is high; certainty is not.

## If We Had More Time

1. **Challenge 9 (The Survey)** — automate what we did manually. Parallel Task subagents per workload would surface cross-workload coupling automatically.
2. **Real screenshot of the running stack** — instead of validation evidence, an actual `docker compose up` capture and a working `/health` curl.
3. **Cost modeling slide with real numbers** — the 3-year TCO in the CTO runbook is rough; sized projections require 30-day post-cutover usage data.
4. **First-pass review of candidate adjacent workloads** — SMTP relay, backup/archive, Jenkins CI, SFTP, internal wiki, monitoring stack. Typically 30–40% of total on-prem cost when aggregated.

## How We Used Claude Code

- **PreToolUse hook (`.claude/settings.json`)** — deterministic block on plaintext secrets in `.tf` files. Caught two instances during IaC generation. Hook regex tested against 7 cases; all pass.
- **Three-level CLAUDE.md** — project-level + per-workload (`web-app/`, `batch/`, `reporting-db/`). Kept four parallel team members aligned without verbal syncing.
- **Stakeholder roleplay** — directed Claude to play SRE / DBA / batch job owner. Surfaced four hidden dependencies (hardcoded IP, NFS mount, warm-ping cron, credential sprawl) in under five minutes.
- **Two-pass architecture review** — Claude helped us pressure-test our first-pass service selections against a 15-year reversibility horizon. Three of four decisions reversed (ECS → EKS, RDS → Aurora, read replica → Redshift Serverless). The team made the calls; Claude made the analysis faster and more rigorous.
- **Plan Mode** — used for any change to IaC modules, state backends, or cutover sequencing. Direct execution for safe, reversible changes.

The architecture decisions are ours. Claude was a force multiplier on analysis, drafting, and consistency — not the decision-maker.
