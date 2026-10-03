#!/bin/sh
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
case "${1:-}" in backup|restore-new) ;; *) echo 'Usage: personal-agent-backup.sh backup DEST | restore-new DUMP' >&2; exit 64;; esac
file=${2:?Specify backup path}
if [ "$1" = backup ]; then
 test ! -e "$file" || { echo 'Refusing overwrite' >&2; exit 64; }
 tmp="$file.partial.$$"
 trap 'rm -f "$tmp"' EXIT HUP INT TERM
 docker compose --env-file deploy/personal-agent/.env -f deploy/personal-agent/compose.yaml -p personal-agent exec -T postgres pg_dump -U agent -d personal_agent -Fc > "$tmp"
 test -s "$tmp"
 mv "$tmp" "$file"
 trap - EXIT HUP INT TERM
 echo 'Backup created; includes sensitive user data. Encrypt and protect it before transfer.'
else
 test -r "$file"
 target="personal_agent_restore_$(date -u +%Y%m%d_%H%M%S)"
 docker compose --env-file deploy/personal-agent/.env -f deploy/personal-agent/compose.yaml -p personal-agent exec -T postgres createdb -U agent "$target"
 docker compose --env-file deploy/personal-agent/.env -f deploy/personal-agent/compose.yaml -p personal-agent exec -T postgres pg_restore -U agent -d "$target" --exit-on-error < "$file"
 docker compose --env-file deploy/personal-agent/.env -f deploy/personal-agent/compose.yaml -p personal-agent exec -T postgres psql -U agent -d "$target" -v ON_ERROR_STOP=1 -c 'SELECT count(*) AS runs FROM agent_runs; SELECT count(*) AS memories FROM agent_memories; SELECT count(*) AS schedules FROM agent_schedules; SELECT count(*) AS artifacts FROM agent_artifacts;'
 echo "Restored into NEW database $target; active database unchanged. Verify object-store backup separately."
fi
