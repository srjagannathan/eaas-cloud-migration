# CLAUDE.md — reporting-db workload

Postgres reporting database. Primary handles writes (web app, batch job). Read replica handles all reporting queries.

## Rules for this workload

- **Read replica endpoint only for queries** — never point reporting scripts or BI tools at the primary endpoint
- **Schema changes via `schema.sql`** — do not alter the schema outside this file; Alembic migrations are Phase 2
- **No credential literals** — connection strings always via env vars; reporting team users are IAM-authenticated on the read replica in cloud
- **`daily_summary` view is the public API** — reporting teams query this view, not raw tables directly

## Local schema setup

```bash
# Apply schema to local Postgres (from repo root with docker compose running)
docker compose exec postgres psql -U contoso -d contoso -f /docker-entrypoint-initdb.d/schema.sql
```

## Cross-workload dependencies (from Discovery)

- Web app writes to `transactions` and `accounts` tables on the primary
- Batch job reads from both tables on the read replica
- Five reporting teams query `daily_summary` view on the read replica
- All connection strings must point to `REPORTING_DB_URL` (read replica), not `DATABASE_URL` (primary)

## Cloud deployment notes

In AWS: RDS multi-AZ primary for writes, one read replica for reads. All five teams must update connection strings from `192.168.10.45` to the RDS read-replica DNS endpoint before cutover. Credentials must be rotated from the shared admin user to individual IAM-authenticated users.
