# CLAUDE.md — batch workload

Nightly reconciliation job. Runs as AWS Batch job triggered by EventBridge. Must be idempotent.

## Rules for this workload

- **Idempotency required** — re-running for the same `RUN_DATE` must produce the same output and not cause errors
- **Output to S3, never local filesystem** — the on-prem NFS mount is gone; writes go to `s3://<S3_BUCKET>/reconciliation/<date>/`
- **Reads from RDS read replica** — do not connect to the primary for reporting queries
- **Explicit `RUN_DATE`** — always pass the date explicitly via env var; never infer "today" in the job logic (breaks reruns)
- **Non-root user** — `appuser` in Dockerfile

## Running locally

```bash
# From repo root — requires full docker compose stack
docker compose run --rm batch

# Specific date rerun
docker compose run --rm -e RUN_DATE=2026-04-30 batch
```

## Environment variables

| Variable | Local default | AWS value |
|---|---|---|
| `DATABASE_URL` | `postgresql://contoso:contoso@localhost:5432/contoso` | SSM Parameter Store |
| `S3_ENDPOINT` | `http://minio:9000` | *(omit for real S3)* |
| `S3_BUCKET` | `contoso-reports` | `contoso-reports-prod` |
| `RUN_DATE` | yesterday (auto) | set by EventBridge input transformer |
