#!/usr/bin/env python3
"""Verify Redis-backed code expiry on the isolated local iOS acceptance stack.

Usage: python3 scripts/test-environment/ios-phone-expiry-test.py
Requires the ignored phone-login-local.json and mock-only compose override.
Only this script's newly requested code has its TTL shortened; no account is seeded.
"""
import json
import pathlib
import secrets
import subprocess
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "artifacts/ios-v5-acceptance"
BASE = "http://127.0.0.1:23000"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, headers={"Content-Type": "application/json"})
    try:
        response = opener.open(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, json.load(response)


def redis(*args):
    return subprocess.check_output([
        "docker", "exec", "openclaw-bot-chat-test-redis-1", "redis-cli", "--raw", *args
    ], text=True).strip()


def main():
    container = json.loads(subprocess.check_output([
        "docker", "inspect", "openclaw-bot-chat-test-backend-1"
    ]))[0]
    env = dict(value.split("=", 1) for value in container["Config"]["Env"] if "=" in value)
    assert env.get("APP_MODE") == "debug"
    assert env.get("SMS_PROVIDER") == env.get("CAPTCHA_PROVIDER") == "mock"
    private = json.loads((ARTIFACTS / "phone-login-local.json").read_text())
    assert env.get("AUTH_PHONE_MOCK_CODE") == private["code"]
    phone = "199" + "".join(str(secrets.randbelow(10)) for _ in range(8))
    key = "phoneauth:code:login:86:" + phone
    status, _ = request("/api/v1/auth/phone/code", {"phone": phone, "captcha_token": "mock", "purpose": "login"})
    assert status == 200
    original_ttl = int(redis("TTL", key))
    assert 0 < original_ttl <= 300
    assert redis("EXPIRE", key, "1") == "1"
    time.sleep(1.5)
    assert redis("EXISTS", key) == "0"
    status, result = request("/api/v1/auth/phone/login", {"phone": phone, "code": private["code"]})
    assert status == 401 and result["message"] == "invalid or expired verification code"
    assert not result.get("data")
    sql = "SELECT count(*) FROM users WHERE phone_country_code='86' AND phone_number='" + phone + "' AND deleted_at IS NULL;"
    query = subprocess.run([
        "docker", "exec", "-i", "openclaw-bot-chat-test-postgres-1", "sh", "-c",
        'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'
    ], input=sql, text=True, capture_output=True, check=True)
    accounts = int(query.stdout.strip())
    assert accounts == 0
    evidence = {"scope": "real local API, Redis and PostgreSQL; mock SMS; shortened TTL", "result": "passed",
                "original_code_ttl_positive": original_ttl > 0, "code_expired_in_redis": True,
                "expired_login_status": status, "accounts_created": accounts}
    (ARTIFACTS / "phone-login-expiry-summary.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence))


if __name__ == "__main__":
    main()
