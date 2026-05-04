"""Smoke tests — basic liveness checks that must pass before any deeper validation."""
import os
import urllib.request
import urllib.error
import json
import pytest

WEB_APP_URL = os.environ.get("WEB_APP_URL", "http://localhost:8000")


def _get(path: str) -> tuple[int, dict]:
    url = f"{WEB_APP_URL}{path}"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, {}


def test_health_returns_200():
    status, body = _get("/health")
    assert status == 200, f"Expected 200, got {status}"


def test_health_has_status_ok():
    _, body = _get("/health")
    assert body.get("status") == "ok"


def test_health_has_timestamp():
    _, body = _get("/health")
    assert "timestamp" in body


def test_accounts_returns_200():
    status, _ = _get("/accounts")
    assert status == 200


def test_accounts_returns_list():
    _, body = _get("/accounts")
    assert isinstance(body, list)


def test_transactions_returns_200():
    status, _ = _get("/transactions")
    assert status == 200


def test_reports_returns_list():
    status, body = _get("/reports")
    assert status == 200
    assert isinstance(body, list)
