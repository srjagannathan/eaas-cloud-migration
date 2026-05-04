"""Contract tests — verify each cloud stand-in is reachable and functional."""
import uuid
import pytest


def test_postgres_connection(db_conn):
    with db_conn.cursor() as cur:
        cur.execute("SELECT 1")
        assert cur.fetchone()[0] == 1


def test_postgres_accounts_table_exists(db_conn):
    with db_conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM accounts")
        count = cur.fetchone()[0]
    assert count >= 0


def test_postgres_transactions_table_exists(db_conn):
    with db_conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM transactions")
        count = cur.fetchone()[0]
    assert count >= 0


def test_postgres_insert_and_read(db_conn):
    account_id = f"TEST-{uuid.uuid4().hex[:8].upper()}"
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO accounts (account_id, name, account_type, balance) VALUES (%s, %s, %s, %s)",
            (account_id, "Test Account", "checking", 100.00),
        )
        db_conn.commit()
        cur.execute("SELECT name FROM accounts WHERE account_id = %s", (account_id,))
        row = cur.fetchone()
    assert row is not None
    assert row[0] == "Test Account"
    # Cleanup
    with db_conn.cursor() as cur:
        cur.execute("DELETE FROM accounts WHERE account_id = %s", (account_id,))
    db_conn.commit()


def test_redis_set_and_get(redis_client):
    key = f"test:{uuid.uuid4().hex}"
    redis_client.set(key, "contoso", ex=30)
    assert redis_client.get(key) == "contoso"
    redis_client.delete(key)


def test_redis_ping(redis_client):
    assert redis_client.ping() is True


def test_s3_bucket_accessible(s3_client):
    import os
    bucket = os.environ.get("S3_BUCKET", "contoso-reports")
    try:
        s3_client.head_bucket(Bucket=bucket)
        accessible = True
    except Exception:
        accessible = False
    assert accessible, f"S3 bucket '{bucket}' is not accessible"


def test_s3_put_and_get(s3_client):
    import os
    bucket = os.environ.get("S3_BUCKET", "contoso-reports")
    key = f"test/contract-test-{uuid.uuid4().hex}.txt"
    content = b"contract test content"
    s3_client.put_object(Bucket=bucket, Key=key, Body=content)
    obj = s3_client.get_object(Bucket=bucket, Key=key)
    assert obj["Body"].read() == content
    s3_client.delete_object(Bucket=bucket, Key=key)
