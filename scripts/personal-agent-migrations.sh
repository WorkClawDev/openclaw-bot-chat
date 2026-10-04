#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
# Replay only in a new restored rehearsal database, never the active database.
target=${1:?Supply personal_agent_restore_TIMESTAMP database}
case "$target" in personal_agent_restore_[0-9]*) ;; *) echo 'Only an isolated restored rehearsal database is accepted' >&2; exit 64;; esac
case "$target" in *[!a-zA-Z0-9_]*) exit 64;; esac
for suffix in approvals journal runs artifacts memory_schedules event_outbox; do
 file="backend/migrations/20261003_agent_$suffix.sql"
 docker compose --env-file deploy/personal-agent/.env -f deploy/personal-agent/compose.yaml -p personal-agent exec -T postgres psql -U agent -d "$target" -v ON_ERROR_STOP=1 --single-transaction < "$file"
done
docker compose --env-file deploy/personal-agent/.env -f deploy/personal-agent/compose.yaml -p personal-agent exec -T postgres psql -U agent -d "$target" -v ON_ERROR_STOP=1 --single-transaction < backend/migrations/20261004_user_roles.sql
docker compose --env-file deploy/personal-agent/.env -f deploy/personal-agent/compose.yaml -p personal-agent exec -T postgres psql -U agent -d "$target" -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM agent_runs; SELECT count(*) FROM agent_run_events; SELECT count(*) FROM agent_schedule_occurrences;"
