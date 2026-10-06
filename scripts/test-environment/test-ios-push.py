#!/usr/bin/env python3
"""Run push acceptance against the existing isolated localhost test PostgreSQL.

Start its postgres service first. Credentials stay in process environment; this
runner never prints them. Tests create/drop only their own temporary schemas.
"""
import os
from pathlib import Path
import shlex
import subprocess
import sys
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
values = {}
for line in (ROOT / ".env.test").read_text().splitlines():
    if "=" not in line or line.lstrip().startswith("#"):
        continue
    key, value = line.split("=", 1)
    if key.strip() in {"DATABASE_USER", "DATABASE_PASSWORD", "DATABASE_DBNAME", "TEST_DATABASE_PORT"}:
        parsed = shlex.split(value, comments=True)
        values[key.strip()] = parsed[0] if parsed else ""
port = int(values.get("TEST_DATABASE_PORT", "15432"))
env = os.environ.copy()
env["PUSH_TEST_DATABASE_DSN"] = (
    "postgresql://" + quote(values["DATABASE_USER"], safe="") + ":"
    + quote(values["DATABASE_PASSWORD"], safe="") + f"@127.0.0.1:{port}/"
    + quote(values["DATABASE_DBNAME"], safe="") + "?sslmode=disable"
)
raise SystemExit(subprocess.call(
    ["go", "test", "./...", "-count=1", *sys.argv[1:]], cwd=ROOT / "backend", env=env
))
