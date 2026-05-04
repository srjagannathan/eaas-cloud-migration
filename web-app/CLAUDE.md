# CLAUDE.md — web-app workload

Python FastAPI web app, containerized for ECS Fargate. All config via environment variables.

## Rules for this workload

- **Health check endpoint** `GET /health` must always return 200 — never remove or break it
- **Non-root user** — `appuser` in Dockerfile; do not change to root
- **No hardcoded IPs or DSNs** — all connection info via env vars (`DATABASE_URL`, `REDIS_URL`, `S3_ENDPOINT`)
- **S3 report access via pre-signed URLs only** — no public ACLs, no direct bucket reads from browser

## Local dev

```bash
# From repo root — starts web app plus all dependencies
docker compose up -d

# Or run locally (requires Postgres, Redis, MinIO running)
cd web-app && pip install -r requirements.txt
python src/init_db.py      # seed the database once
uvicorn src.main:app --reload --port 8000
```

## Environment variables

| Variable | Local default | AWS value |
|---|---|---|
| `DATABASE_URL` | `postgresql://contoso:contoso@localhost:5432/contoso` | SSM Parameter Store |
| `REDIS_URL` | `redis://localhost:6379` | SSM Parameter Store |
| `S3_ENDPOINT` | `http://localhost:9000` | *(omit for real S3)* |
| `S3_BUCKET` | `contoso-reports` | `contoso-reports-prod` |
| `AWS_ACCESS_KEY_ID` | `minioadmin` | ECS task role (no key needed) |
| `AWS_SECRET_ACCESS_KEY` | `minioadmin` | ECS task role (no secret needed) |

## Cloud deployment notes

The same image deploys to ECS Fargate by swapping env vars — no rebuild needed. In AWS, remove `S3_ENDPOINT` (boto3 uses the real S3 endpoint by default) and remove `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (ECS task role provides credentials via instance metadata).
