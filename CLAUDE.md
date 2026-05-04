# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: Contoso Financial Cloud Migration (Hackathon Scenario 2)

Three on-prem workloads migrated to AWS. Local stack uses cloud-equivalent stand-ins. Every workload directory has its own `CLAUDE.md` with workload-specific guidance.

## Stack

| Component | Local stand-in | AWS target |
|---|---|---|
| Web app | FastAPI container (port 8000) | ECS Fargate |
| Batch job | Python script + cron | AWS Batch / EventBridge |
| Reporting DB | Postgres 15 (port 5432) | RDS Postgres multi-AZ |
| Cache | Redis 7 (port 6379) | ElastiCache Redis |
| Object store | MinIO (port 9000) | S3 |
| IaC | Terraform (local validate only) | AWS provider |

## Secrets Rule — READ THIS FIRST

**NEVER write literal credential values in `.tf` files or any config committed to git.**
Use `var.` references for all secrets. In AWS, source from `data.aws_secretsmanager_secret_version`.

A `PreToolUse` hook in `.claude/settings.json` will **block** any file edit that contains a plaintext secret pattern. This is not optional — see `decisions/ADR-003-secrets-hook-vs-prompt.md` for why a hook rather than a prompt.

For local development secrets, use `.env` (gitignored). Copy from `.env.example`.

## Per-Workload CLAUDE.md

Each workload has its own guidance:
- [`web-app/CLAUDE.md`](web-app/CLAUDE.md) — FastAPI, health check required, non-root Docker user
- [`batch/CLAUDE.md`](batch/CLAUDE.md) — idempotency required, output to S3 not local filesystem
- [`reporting-db/CLAUDE.md`](reporting-db/CLAUDE.md) — read replica endpoint only, Alembic for migrations

## Commands

```bash
# Start local stack
docker compose up -d

# Run tests
cd tests && uv run pytest -v
cd tests && uv run pytest smoke/ -v          # smoke only
cd tests && uv run pytest -k test_integrity  # single suite

# Build web app image
docker build -t contoso-web ./web-app

# IaC validation (no live deploy)
cd infra && terraform init && terraform validate && terraform plan -var-file=local.tfvars

# Stop stack
docker compose down
```

## Architecture Decision Records

All significant decisions live in `decisions/`. Before proposing an architectural change, check whether an ADR already covers the decision space.

- `ADR-001` — Migration pattern (lift-and-shift first)
- `ADR-002` — Target AWS services per workload
- `ADR-003` — Secrets: hook vs. prompt enforcement

## Claude Code Config Notes

- **Plan Mode**: use for any change to IaC modules or cutover sequencing
- **Non-interactive CI**: `claude --no-interactive` runs IaC review in CI with read-only tools
- **Subagents**: use the Task tool with explicit context per call — subagents do not inherit coordinator context
