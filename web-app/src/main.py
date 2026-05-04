import os
import json
import uuid
from datetime import datetime
from typing import Optional

import redis
import boto3
import psycopg2
import psycopg2.extras
from botocore.client import Config
from fastapi import FastAPI, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

app = FastAPI(title="Contoso Financial Web App", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://contoso:contoso@localhost:5432/contoso")
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379")
S3_ENDPOINT = os.environ.get("S3_ENDPOINT", "http://localhost:9000")
S3_BUCKET = os.environ.get("S3_BUCKET", "contoso-reports")
AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID", "minioadmin")
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", "minioadmin")


def get_db():
    conn = psycopg2.connect(DATABASE_URL)
    try:
        yield conn
    finally:
        conn.close()


def get_redis():
    return redis.from_url(REDIS_URL, decode_responses=True)


def get_s3():
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        aws_access_key_id=AWS_ACCESS_KEY_ID,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
        config=Config(signature_version="s3v4"),
        region_name="us-east-1",
    )


class Transaction(BaseModel):
    account_id: str
    amount: float
    description: str
    transaction_type: str = "debit"


@app.get("/health")
def health():
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat()}


@app.get("/accounts")
def list_accounts(db=Depends(get_db)):
    with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM accounts ORDER BY created_at DESC LIMIT 100")
        return cur.fetchall()


@app.get("/accounts/{account_id}")
def get_account(account_id: str, db=Depends(get_db)):
    with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM accounts WHERE account_id = %s", (account_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Account not found")
    return row


@app.post("/transactions", status_code=201)
def create_transaction(tx: Transaction, db=Depends(get_db)):
    tx_id = str(uuid.uuid4())
    with db.cursor() as cur:
        cur.execute(
            """INSERT INTO transactions (transaction_id, account_id, amount, description, transaction_type, created_at)
               VALUES (%s, %s, %s, %s, %s, %s)""",
            (tx_id, tx.account_id, tx.amount, tx.description, tx.transaction_type, datetime.utcnow()),
        )
    db.commit()
    return {"transaction_id": tx_id, "status": "created"}


@app.get("/transactions")
def list_transactions(account_id: Optional[str] = None, db=Depends(get_db)):
    with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        if account_id:
            cur.execute(
                "SELECT * FROM transactions WHERE account_id = %s ORDER BY created_at DESC LIMIT 200",
                (account_id,),
            )
        else:
            cur.execute("SELECT * FROM transactions ORDER BY created_at DESC LIMIT 200")
        return cur.fetchall()


@app.get("/reports")
def list_reports():
    s3 = get_s3()
    try:
        s3.head_bucket(Bucket=S3_BUCKET)
    except Exception:
        return []
    response = s3.list_objects_v2(Bucket=S3_BUCKET, Prefix="reconciliation/", MaxKeys=50)
    objects = response.get("Contents", [])
    result = []
    for obj in objects:
        url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET, "Key": obj["Key"]},
            ExpiresIn=3600,
        )
        result.append({"key": obj["Key"], "size": obj["Size"], "last_modified": obj["LastModified"].isoformat(), "url": url})
    return result
