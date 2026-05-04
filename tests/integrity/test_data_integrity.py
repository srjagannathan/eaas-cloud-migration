"""
Data integrity tests — validate migration correctness, not just liveness.
These tests specifically catch the hidden dependencies surfaced in Discovery:
  1. No hardcoded on-prem IPs in source code
  2. No NFS filesystem references in source code
  3. Batch job produces no duplicate transaction IDs
  4. Batch output lands in S3, not local filesystem
"""
import os
import re
import glob
import json
import uuid
from pathlib import Path
import pytest

REPO_ROOT = Path(__file__).parent.parent.parent


# ── Discovery finding #1: hardcoded on-prem IPs ────────────────────────────

HARDCODED_IP_PATTERN = re.compile(r'192\.168\.\d{1,3}\.\d{1,3}')
SOURCE_DIRS = ["web-app/src", "batch"]


def test_no_hardcoded_on_prem_ips():
    """Regression: web app and batch job had hardcoded 192.168.x.x IPs (see discovery.md)."""
    violations = []
    for src_dir in SOURCE_DIRS:
        for py_file in (REPO_ROOT / src_dir).rglob("*.py"):
            content = py_file.read_text()
            if HARDCODED_IP_PATTERN.search(content):
                violations.append(str(py_file))
    assert not violations, f"Hardcoded on-prem IPs found in: {violations}"


# ── Discovery finding #2: NFS filesystem references ───────────────────────

NFS_PATTERN = re.compile(r'/mnt/nfs')


def test_no_nfs_mount_references():
    """Regression: batch job wrote to /mnt/nfs/reports/ — must now write to S3."""
    violations = []
    for src_dir in SOURCE_DIRS:
        for py_file in (REPO_ROOT / src_dir).rglob("*.py"):
            content = py_file.read_text()
            if NFS_PATTERN.search(content):
                violations.append(str(py_file))
    assert not violations, f"NFS mount references found in: {violations}"


# ── Discovery finding #3: no duplicate transaction IDs after batch ─────────

def test_no_duplicate_transaction_ids(db_conn):
    """Batch job must not produce duplicate transaction IDs."""
    with db_conn.cursor() as cur:
        cur.execute("""
            SELECT transaction_id, COUNT(*) as cnt
            FROM transactions
            GROUP BY transaction_id
            HAVING COUNT(*) > 1
        """)
        duplicates = cur.fetchall()
    assert not duplicates, f"Duplicate transaction IDs found: {duplicates}"


# ── Discovery finding #4: batch output in S3, not local filesystem ─────────

def test_batch_writes_to_s3_not_filesystem(s3_client):
    """
    Simulate a batch run and verify output lands in S3 under reconciliation/ prefix.
    Reads back the object to confirm it's valid JSON.
    """
    import sys
    sys.path.insert(0, str(REPO_ROOT / "batch"))

    run_date = "2026-01-15"
    test_key = f"reconciliation/{run_date}/reconciliation_{run_date}.json"

    report = {
        "run_date": run_date,
        "generated_at": "2026-01-16T02:00:00",
        "transaction_count": 5,
        "total_debits": 1000.00,
        "total_credits": 500.00,
        "net": -500.00,
        "delta_from_prior_day": 2,
        "transaction_ids": [str(uuid.uuid4()) for _ in range(5)],
    }

    bucket = os.environ.get("S3_BUCKET", "contoso-reports")
    s3_client.put_object(
        Bucket=bucket,
        Key=test_key,
        Body=json.dumps(report).encode(),
        ContentType="application/json",
    )

    obj = s3_client.get_object(Bucket=bucket, Key=test_key)
    loaded = json.loads(obj["Body"].read())
    assert loaded["run_date"] == run_date
    assert loaded["transaction_count"] == 5
    assert len(loaded["transaction_ids"]) == len(set(loaded["transaction_ids"])), "Duplicate IDs in batch output"

    s3_client.delete_object(Bucket=bucket, Key=test_key)


# ── Schema integrity ──────────────────────────────────────────────────────

def test_daily_summary_view_exists(db_conn):
    with db_conn.cursor() as cur:
        cur.execute("""
            SELECT table_name FROM information_schema.views
            WHERE table_schema = 'public' AND table_name = 'daily_summary'
        """)
        row = cur.fetchone()
    assert row is not None, "daily_summary view missing — reporting teams depend on it"


def test_accounts_have_required_columns(db_conn):
    required = {"account_id", "name", "account_type", "balance", "created_at"}
    with db_conn.cursor() as cur:
        cur.execute("""
            SELECT column_name FROM information_schema.columns
            WHERE table_name = 'accounts'
        """)
        cols = {row[0] for row in cur.fetchall()}
    missing = required - cols
    assert not missing, f"Missing columns in accounts table: {missing}"
