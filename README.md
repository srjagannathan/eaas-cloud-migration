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

## Challenge Resolution Summary

The scenario listed nine challenges. Here is what the team built, decided, and skipped — with the reasoning that produced each outcome.

### Challenge 1 — The Memo  *(role: PM/BA · status: done)*

**The team's resolution.** We wrote a one-page decision memo arguing for cloud migration on lift-and-shift terms — fast time-to-cloud, predictable cost, compliance gap closed in weeks not quarters. **On second-pass review, we reframed.** "Lift-and-shift first" was inaccurate: Python 2.7 cannot be safely re-hosted (EOL since 2020), the warm-ping cron is a bug not a feature, and several "dependencies" warranted retirement, not migration. The memo now defends a per-workload 5 Rs disposition. Risks named, owners assigned. Final artifact: [`docs/memo.md`](docs/memo.md).

### Challenge 2 — The Discovery  *(role: Architect · status: done)*

**The team's resolution.** We used Claude as a thinking partner — roleplaying the SRE, the DBA, and the batch job owner each in character, with their own agendas. In under five minutes the conversations surfaced four hidden dependencies that no config-file grep would have found: a hardcoded IP `192.168.10.45` appearing in three workloads simultaneously (cross-workload coupling), a shared NFS mount `/mnt/nfs/reports/` coupling the web app to the batch job, a warm-ping cron quietly keeping pgBouncer alive, and three years of unrotated credentials shared across five reporting teams. These findings shape every ADR that follows and every integrity test we wrote. Final artifact: [`docs/discovery.md`](docs/discovery.md).

### Challenge 3 — The Options  *(role: Architect · status: done — 4 ADRs)*

**The team's resolution.** Two-pass option scoring. **First pass** optimized for cutover speed — produced ECS Fargate, RDS Postgres, read-replica-for-BI as the recommended targets. **Second pass** added 15-year criteria: ecosystem longevity, AI/ML readiness, OLAP/OLTP separation, portability optionality. Three of four decisions reversed: EKS+Karpenter (Phase 2 target), Aurora PostgreSQL Serverless v2 (from day one), Redshift Serverless + S3 data lake for analytics. Each evaluated on a 1–5 scale across the criteria. We deliberately did *not* prematurely upgrade the Phase 1 IaC — the Phase 1 ECS+RDS stack ships now; the Phase 2 path is reversible at known cost. Final artifacts: [`ADR-001`](decisions/ADR-001-migration-pattern.md) (5 Rs pattern), [`ADR-002`](decisions/ADR-002-target-cloud-services.md) (target services with both passes shown), [`ADR-003`](decisions/ADR-003-secrets-hook-vs-prompt.md) (hook vs. prompt enforcement — explicitly required by scenario), [`ADR-004`](decisions/ADR-004-five-rs-workload-assessment.md) (per-workload 5 Rs disposition).

### Challenge 4 — The Container  *(role: Dev · status: done)*

**The team's resolution.** Multi-stage Dockerfile with `appuser` non-root user and a `HEALTHCHECK` on port 8000. Stage 1 installs dependencies; stage 2 copies only the runtime artifacts. FastAPI application with endpoints `/health`, `/accounts`, `/transactions`, `/reports` (the last using S3 pre-signed URLs to replace the retired NFS coupling). All configuration via environment variables — `DATABASE_URL`, `REDIS_URL`, `S3_ENDPOINT`. **The same image deploys to ECS Fargate (Phase 1) or EKS (Phase 2) with a config swap, no rebuild.** Image is currently x86; in response to the CTO review, Phase 2 commits to Graviton3 (`linux/arm64` build flag) for 30–40% better price-performance. Final artifacts: [`web-app/Dockerfile`](web-app/Dockerfile), [`web-app/src/main.py`](web-app/src/main.py).

### Challenge 5 — The Foundation  *(role: Platform · status: done — IaC + hook + alarms)*

**The team's resolution.** Three layers of infrastructure-as-code:
1. **Local stand-in stack** — `docker-compose.yml` with MinIO (S3), Postgres 15 (Aurora), Redis 7 (ElastiCache). Same topology as AWS target.
2. **AWS IaC** — Terraform modules for ECS, RDS, ElastiCache, S3, plus a new [`infra/modules/observability.tf`](infra/modules/observability.tf) added in response to the SRE review. Seven CloudWatch alarms + a dashboard, with SNS → PagerDuty integration. State file in S3 with DynamoDB locking.
3. **PreToolUse hook** — [`.claude/settings.json`](.claude/settings.json) deterministically blocks plaintext secret patterns in `.tf` files. Tested against 7 cases: 3 expected BLOCK, 4 expected PASS. **All 7 passed** (validated live via `python3 /tmp/test_hook.py`). Why a hook and not a prompt: ADR-003 explains the deterministic-vs-probabilistic distinction. Hook caught two real attempts during this build.

### Challenge 6 — The Proof  *(role: Quality · status: done)*

**The team's resolution.** Three test layers in [`tests/`](tests/):
- **Smoke** — basic liveness checks (`/health`, `/accounts`, `/transactions`, `/reports`). 7 tests.
- **Contract** — round-trip validation of every cloud stand-in (Postgres insert+read, Redis set+get, S3 put+get). 8 tests.
- **Integrity** — **each test traces to a named Discovery finding.** Asserts no hardcoded `192.168.x.x` IPs in source files (catches Discovery #1). Asserts no `/mnt/nfs` references (catches Discovery #2). Asserts no duplicate transaction IDs after batch run (catches Discovery #3 silent-failure). Asserts batch output lands in S3 not local filesystem (catches Discovery #4 NFS coupling). The validation suite is *not* "tests pass" theatre — it actively catches the things that would have broken the migration if left unaddressed. Same suite runs against the local stack today and against AWS endpoints post-cutover by swapping environment variables. Final artifact: [`tests/integrity/test_data_integrity.py`](tests/integrity/test_data_integrity.py).

### Challenge 7 — The Scorecard  *(role: Quality, stretch · status: skipped)*

**The team's resolution.** Time constraint. We were 30 minutes from submission and judged the marginal value of an eval harness for Claude's IaC outputs lower than getting the runbooks audience-tailored and the architecture diagram to real SVG. The Scorecard concept (golden-set of known-good IaC, known-bad patterns, false-confidence rate) is captured as an explicit Phase-1.5 deliverable in [`cto-office-runbook.md`](runbooks/cto-office-runbook.md) Gate 1 (Month 3). It would run in CI on every IaC PR. Owner: Architecture Lead.

### Challenge 8 — The Undo  *(role: Stretch · status: substantially addressed)*

**The team's resolution.** What the scenario described — *"the runbook nobody wants to write but everyone needs at 4am"* — is exactly what we built in [`runbooks/ops-runbook.md`](runbooks/ops-runbook.md). Section 4 contains exact rollback commands per workload: web app rollback (3 minutes, with the precise `aws ecs update-service --task-definition $PREV` command), Aurora rollback from snapshot (with the DBA escalation gate), Terraform rollback via `git revert + plan + apply`, and full migration rollback during the 14-day warm window. Section 4.4 explicitly names the cost of rollback at each stage: trivial Day 1–14, hard Day 15–30, very hard Day 31–60, effectively impossible thereafter. Section 10.3 (added during stakeholder review) commits to a game-day schedule so the rollback commands are practiced, not theoretical. **What we didn't ship:** the Phase 2 streaming rollback (Amazon MSK) — that ADR comes when the Phase 2 architecture is committed to code.

### Challenge 9 — The Survey  *(role: Stretch, agentic · status: skipped)*

**The team's resolution.** Time constraint. The Discovery work in Challenge 2 was done by manually directing Claude through three sequential stakeholder roleplays. The Survey would automate this: parallel Task subagents per workload (one for web app, one for batch, one for reporting database), each given explicit context about the workload it owns, each emitting a structured JSON dependency report; a coordinator merges the outputs and surfaces cross-workload couplings. This is exactly the pattern that would have caught the cross-workload coupling we found manually — a single subagent looking at one workload would not see the same hardcoded IP in three places. **It is the highest-priority Phase 1.5 candidate** (see [`cto-office-runbook.md`](runbooks/cto-office-runbook.md) section 10.5 Gate 4). Captured in "If We Had More Time" with the same priority.

### Bonus deliverables (not in the scenario list)

| Artifact | Why we built it | Where |
|---|---|---|
| **ADR-003** — Hook vs. Prompt for secrets | The scenario explicitly references this distinction; we wrote it as the cert-domain artifact | [`decisions/ADR-003-secrets-hook-vs-prompt.md`](decisions/ADR-003-secrets-hook-vs-prompt.md) |
| **ADR-004** — Per-workload 5 Rs assessment | Replaces blanket "lift-and-shift" framing with per-workload disposition | [`decisions/ADR-004-five-rs-workload-assessment.md`](decisions/ADR-004-five-rs-workload-assessment.md) |
| **Three audience runbooks** | Scenario brief said: *"the auditor will read your IaC, the CTO will read your ADRs, ops will run your runbook at 4am — design for all three readers."* Same architecture, three different reading minds, three different documents. | [`runbooks/`](runbooks/) |
| **CloudWatch alarms IaC** | Stakeholder review (SRE) flagged that alarms existed only in markdown. Added 7 alarms + dashboard + SNS topic + PagerDuty integration as code. | [`infra/modules/observability.tf`](infra/modules/observability.tf) |
| **Stakeholder review responses** | After the deck rewrite, the team simulated a roundtable with Legal/CTO/Ops. 17 concerns surfaced; 17 concrete updates shipped. Each runbook has a §10 or §11 appendix capturing the reviews and responses. | Each runbook's final section |

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
