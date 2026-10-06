#!/usr/bin/env python3
"""Accept atomic phone-code redemption against the isolated iOS test backend.

Uses real Go/Redis/PostgreSQL and explicitly checked mock SMS/captcha only.
Requires the ignored phone-login-local.json and mock-only compose override.
No credentials or phone identifiers are saved in the result artifact.
"""
import concurrent.futures
import json
import pathlib
import secrets
import subprocess
import threading
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "artifacts/ios-v5-acceptance"
BASE = "http://127.0.0.1:23000"


def request(path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(
        BASE + path, data=None if body is None else json.dumps(body).encode(), headers=headers
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        response = opener.open(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, json.load(response)


def counts(phone):
    assert phone.isdigit() and len(phone) == 11
    sql = """WITH u AS (
        SELECT id FROM users WHERE phone_country_code='86'
        AND phone_number='%s' AND deleted_at IS NULL
    ) SELECT json_build_object(
        'accounts', (SELECT count(*) FROM u),
        'registrations', (SELECT count(*) FROM audit_logs
            WHERE user_id IN (SELECT id FROM u) AND action='phone_register'),
        'logins', (SELECT count(*) FROM audit_logs
            WHERE user_id IN (SELECT id FROM u) AND action='phone_login')
    );""" % phone
    result = subprocess.run([
        "docker", "exec", "-i", "openclaw-bot-chat-test-postgres-1", "sh", "-c",
        'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'
    ], input=sql, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError("local database readback failed")
    return json.loads(result.stdout)


def race(phone, code, success_status):
    workers = 32
    barrier = threading.Barrier(workers, timeout=15)

    def submit():
        barrier.wait()
        return request("/api/v1/auth/phone/login", {"phone": phone, "code": code})

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(lambda _: submit(), range(workers)))
    winners = [body["data"] for status, body in results if status == success_status]
    rejected = [(status, body) for status, body in results if status != success_status]
    assert len(winners) == 1 and len(rejected) == workers - 1, "expected exactly one successful login"
    assert all(status == 401 and body.get("message") == "invalid or expired verification code"
               and not body.get("data") for status, body in rejected), "losers must receive code rejection without tokens"
    winner = winners[0]
    assert winner["user"]["has_password"] is False
    status, me = request("/api/v1/auth/me", token=winner["tokens"]["access_token"])
    assert status == 200 and me["data"]["id"] == winner["user"]["id"]
    return winner["user"]["id"], {
        "requests": workers, "success_status": success_status, "successes": 1,
        "rejected_status": 401, "rejected": workers - 1, "winner_profile_verified": True
    }


def wait_for_counts(phone, expected):
    # Audit writes are asynchronous; wait for the exact expected committed rows.
    deadline = time.monotonic() + 5
    while True:
        observed = counts(phone)
        if observed == expected:
            return observed
        assert all(observed[key] <= value for key, value in expected.items()), "duplicate account or audit"
        assert time.monotonic() < deadline, "audit readback timed out"
        time.sleep(0.1)


def main():
    container = json.loads(subprocess.check_output([
        "docker", "inspect", "openclaw-bot-chat-test-backend-1"
    ]))[0]
    env = dict(value.split("=", 1) for value in container["Config"]["Env"] if "=" in value)
    assert container["State"]["Running"]
    assert env.get("APP_MODE") == "debug"
    assert env.get("SMS_PROVIDER") == env.get("CAPTCHA_PROVIDER") == "mock"
    private = json.loads((ARTIFACTS / "phone-login-local.json").read_text())
    assert env.get("AUTH_PHONE_MOCK_CODE") == private["code"]
    # Only a generated recipient belonging to this test is used.
    phone = "199" + "".join(str(secrets.randbelow(10)) for _ in range(8))
    before = counts(phone)
    assert before == {"accounts": 0, "registrations": 0, "logins": 0}
    status, sent = request("/api/v1/auth/phone/code", {"phone": phone, "captcha_token": "mock"})
    assert status == 200
    issued_at = time.monotonic()
    identity, registration = race(phone, private["code"], 201)
    after_registration = wait_for_counts(phone, {"accounts": 1, "registrations": 1, "logins": 0})
    # Use the configured cooldown; never delete rate-limit keys to bypass it.
    cooldown = int(sent["data"]["cooldown_seconds"])
    assert 0 < cooldown <= 30
    time.sleep(max(0, issued_at + cooldown + 0.2 - time.monotonic()))
    status, _ = request("/api/v1/auth/phone/code", {"phone": phone, "captcha_token": "mock"})
    assert status == 200
    reused, login = race(phone, private["code"], 200)
    assert reused == identity
    after_login = wait_for_counts(phone, {"accounts": 1, "registrations": 1, "logins": 1})
    evidence = {
        "result": "passed", "scope": "real local Go API, Redis and PostgreSQL; mock SMS/captcha",
        "before": before, "registration_race": registration, "after_registration": after_registration,
        "existing_login_race": login, "after_login": after_login, "same_account_reused": True,
    }
    (ARTIFACTS / "phone-concurrency-api-summary.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence))


if __name__ == "__main__":
    main()
