"""
Nightly batch reconciliation job for Contoso Financial.
Migrated from on-prem cron + NFS to AWS Batch + EventBridge + S3.

Idempotency: safe to re-run for the same date — S3 object is overwritten.
Output: s3://<S3_BUCKET>/reconciliation/<date>/reconciliation_<date>.json
"""
import os
import json
import sys
from datetime import datetime, timedelta, date

import boto3
import psycopg2
import psycopg2.extras
from botocore.client import Config

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://contoso:contoso@localhost:5432/contoso")
S3_ENDPOINT = os.environ.get("S3_ENDPOINT", "http://localhost:9000")
S3_BUCKET = os.environ.get("S3_BUCKET", "contoso-reports")
AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID", "minioadmin")
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", "minioadmin")

# Use a specific run date if provided (for reruns), otherwise yesterday
RUN_DATE = os.environ.get("RUN_DATE", (date.today() - timedelta(days=1)).isoformat())


def get_s3():
    kwargs = dict(
        aws_access_key_id=AWS_ACCESS_KEY_ID,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
        config=Config(signature_version="s3v4"),
        region_name="us-east-1",
    )
    if S3_ENDPOINT:
        kwargs["endpoint_url"] = S3_ENDPOINT
    return boto3.client("s3", **kwargs)


def fetch_transactions(run_date: str):
    conn = psycopg2.connect(DATABASE_URL)
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            """SELECT t.*, a.name as account_name
               FROM transactions t
               JOIN accounts a ON t.account_id = a.account_id
               WHERE DATE(t.created_at) = %s
               ORDER BY t.created_at""",
            (run_date,),
        )
        rows = cur.fetchall()
    conn.close()
    return [dict(r) for r in rows]


def load_prior_day_summary(run_date: str, s3):
    prior_date = (datetime.strptime(run_date, "%Y-%m-%d").date() - timedelta(days=1)).isoformat()
    key = f"reconciliation/{prior_date}/reconciliation_{prior_date}.json"
    try:
        obj = s3.get_object(Bucket=S3_BUCKET, Key=key)
        return json.loads(obj["Body"].read())
    except s3.exceptions.NoSuchKey:
        return None
    except Exception:
        return None


def reconcile(transactions: list, prior_summary: dict | None) -> dict:
    total_debits = sum(t["amount"] for t in transactions if t["transaction_type"] == "debit")
    total_credits = sum(t["amount"] for t in transactions if t["transaction_type"] == "credit")
    tx_count = len(transactions)
    tx_ids = [t["transaction_id"] for t in transactions]

    prior_count = prior_summary.get("transaction_count", 0) if prior_summary else 0
    delta = tx_count - prior_count

    return {
        "run_date": RUN_DATE,
        "generated_at": datetime.utcnow().isoformat(),
        "transaction_count": tx_count,
        "total_debits": float(total_debits),
        "total_credits": float(total_credits),
        "net": float(total_credits - total_debits),
        "delta_from_prior_day": delta,
        "transaction_ids": tx_ids,
    }


def ensure_bucket(s3):
    try:
        s3.head_bucket(Bucket=S3_BUCKET)
    except Exception:
        s3.create_bucket(Bucket=S3_BUCKET)


def upload_report(report: dict, s3):
    key = f"reconciliation/{RUN_DATE}/reconciliation_{RUN_DATE}.json"
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=json.dumps(report, indent=2).encode(),
        ContentType="application/json",
    )
    print(f"Report uploaded: s3://{S3_BUCKET}/{key}")
    return key


def main():
    print(f"Starting reconciliation for {RUN_DATE}")
    s3 = get_s3()
    ensure_bucket(s3)

    transactions = fetch_transactions(RUN_DATE)
    print(f"Fetched {len(transactions)} transactions")

    prior_summary = load_prior_day_summary(RUN_DATE, s3)
    report = reconcile(transactions, prior_summary)

    # Detect duplicate transaction IDs — integrity check
    if len(report["transaction_ids"]) != len(set(report["transaction_ids"])):
        print("ERROR: duplicate transaction IDs detected", file=sys.stderr)
        sys.exit(1)

    upload_report(report, s3)
    print(f"Reconciliation complete: {report['transaction_count']} transactions, net {report['net']:.2f}")


if __name__ == "__main__":
    main()
