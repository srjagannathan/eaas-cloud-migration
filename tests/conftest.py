import os
import pytest
import psycopg2
import redis
import boto3
from botocore.client import Config

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://contoso:contoso@localhost:5432/contoso")
REDIS_URL    = os.environ.get("REDIS_URL",    "redis://localhost:6379")
S3_ENDPOINT  = os.environ.get("S3_ENDPOINT",  "http://localhost:9000")
S3_BUCKET    = os.environ.get("S3_BUCKET",    "contoso-reports")
WEB_APP_URL  = os.environ.get("WEB_APP_URL",  "http://localhost:8000")


@pytest.fixture(scope="session")
def db_conn():
    conn = psycopg2.connect(DATABASE_URL)
    yield conn
    conn.close()


@pytest.fixture(scope="session")
def redis_client():
    client = redis.from_url(REDIS_URL, decode_responses=True)
    yield client
    client.close()


@pytest.fixture(scope="session")
def s3_client():
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "minioadmin"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "minioadmin"),
        config=Config(signature_version="s3v4"),
        region_name="us-east-1",
    )
