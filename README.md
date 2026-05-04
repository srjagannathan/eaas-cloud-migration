# Team EAAS_Cloud_Migration

## Participants
- Raymond Clarance (Architect / Platform)
- Venkat Pal (Developer)
- Srinath Jagannathan (PM / Quality)
- Saurabh Aggarwal (Developer / Infrastructure)

## Scenario
Scenario 2: Cloud Migration — "The Lift, the Shift, and the 4am Call"

## What We Built

Contoso Financial's three on-prem workloads — a customer-facing web app, a nightly batch reconciliation job, and a reporting database queried by five teams — migrated to AWS using a lift-and-shift-first pattern.

The repo contains production-ready artifacts that run locally with cloud-equivalent architecture: Docker Compose maps MinIO → S3, Postgres → RDS, and Redis → ElastiCache. A multi-stage Dockerfile produces an image deployable to ECS Fargate with zero rebuild. Terraform IaC covers the full AWS target state. A PreToolUse Claude Code hook deterministically blocks any plaintext secret from being written into `.tf` files. Three ADRs capture the migration pattern, service selection, and the hook-vs-prompt decision for secrets enforcement.

## Challenges Attempted

| # | Challenge | Status | Notes |
|---|---|---|---|
| 1 | The Memo | done | `docs/memo.md` — lift-and-shift first; risks named and owned |
| 2 | The Discovery | done | `docs/discovery.md` — 3 hidden dependencies surfaced via stakeholder roleplay |
| 3 | The Options | done | `decisions/ADR-001` (pattern) + `decisions/ADR-002` (services) + scored options table |
| 4 | The Container | done | FastAPI web app, multi-stage Dockerfile, non-root user, health check |
| 5 | The Foundation | done | Terraform modules (ECS, RDS, ElastiCache, S3) + docker-compose.yml + PreToolUse hook |
| 6 | The Proof | done | Smoke, contract, and integrity tests; run against local stack, rerun post-cutover |
| 7 | The Scorecard | skipped | Time constraint |
| 8 | The Undo | skipped | Time constraint |
| 9 | The Survey | skipped | Time constraint |

## Key Decisions

1. **Lift-and-shift first, optimize later** — faster time-to-cloud, CFO-friendly, compliance residency easier to configure in cloud than mid-refactor. Full rationale in [`decisions/ADR-001-migration-pattern.md`](decisions/ADR-001-migration-pattern.md).

2. **ECS Fargate over EKS** — no node management overhead, right-sized for Contoso's traffic, faster to operationalize. See [`decisions/ADR-002-target-cloud-services.md`](decisions/ADR-002-target-cloud-services.md).

3. **PreToolUse hook for secrets, not just a prompt** — hardcoded secrets in IaC have no legitimate exception; the hook blocks unconditionally. A `CLAUDE.md` prompt adds preference guidance for edge cases. Rationale in [`decisions/ADR-003-secrets-hook-vs-prompt.md`](decisions/ADR-003-secrets-hook-vs-prompt.md).

## How to Run It

Requires: Docker, Docker Compose, Python 3.11+, `uv`

```bash
# Start local cloud-equivalent stack (MinIO, Postgres, Redis, web app)
docker compose up -d

# Run full validation suite
cd tests && uv run pytest -v

# Verify Terraform (no live cloud needed)
cd infra && terraform init && terraform validate

# Stop the stack
docker compose down
```

Web app: http://localhost:8000  
API docs: http://localhost:8000/docs  
MinIO console: http://localhost:9001  

## If We Had More Time

1. **Challenge 9 (The Survey)** — parallel Task subagents for discovery; would surface cross-workload couplings automatically and sharpen the ADRs
2. **Challenge 8 (The Undo)** — per-stage rollback runbook; exists as prose in `docs/discovery.md` but needs exact command sequences
3. **Challenge 7 (Scorecard)** — CI eval harness for IaC outputs; golden set of known-good/bad Terraform snippets with Claude scoring
4. Right-size the ECS task definitions with actual load testing
5. Add Alembic migrations to the reporting DB workload

## How We Used Claude Code

- **Discovery roleplay**: prompted Claude to play each stakeholder (DBA, SRE, batch job owner) and surface undocumented dependencies — found the hardcoded DB IP, the NFS mount, and the warm-ping cron in under 5 minutes
- **IaC generation**: Claude drafted all four Terraform modules; the PreToolUse hook caught two instances where it initially tried to inline placeholder secrets
- **Parallel track coordination**: shared `CLAUDE.md` kept all team members' Claude sessions aligned on naming, stack, and secrets conventions without manual syncing
- **Biggest time save**: Challenge 4 (containerization) — multi-stage Dockerfile with non-root user and health check generated and tested in ~8 minutes
