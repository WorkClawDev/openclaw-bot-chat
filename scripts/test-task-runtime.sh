#!/usr/bin/env bash
set -euo pipefail

API_BASE="${API_BASE:-http://127.0.0.1:8080/api/v1}"
: "${TASK_TEST_USERNAME:?Set TASK_TEST_USERNAME to a disposable local account username}"
: "${TASK_TEST_PASSWORD:?Set TASK_TEST_PASSWORD to the disposable local account password}"

BOT_ID=""
TOKEN=""
TASK_IDS=()

cleanup() {
  if [[ -n "$TOKEN" ]]; then
    for ((index = ${#TASK_IDS[@]} - 1; index >= 0; index--)); do
      curl -fsS -X DELETE "$API_BASE/tasks/${TASK_IDS[index]}" \
        -H "Authorization: Bearer $TOKEN" >/dev/null || true
    done
  fi
  if [[ -n "$TOKEN" && -n "$BOT_ID" ]]; then
    curl -fsS -X DELETE "$API_BASE/bots/$BOT_ID" \
      -H "Authorization: Bearer $TOKEN" >/dev/null || true
  fi
}
trap cleanup EXIT

login_response=$(curl -fsS -X POST "$API_BASE/auth/login" \
  -H "Content-Type: application/json" \
  --data "{\"username\":\"$TASK_TEST_USERNAME\",\"password\":\"$TASK_TEST_PASSWORD\"}")
TOKEN=$(printf "%s" "$login_response" | jq -er ".data.tokens.access_token")

bot_response=$(curl -fsS -X POST "$API_BASE/bots" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  --data '{"name":"task-runtime-smoke","description":"Disposable task runtime verification bot","bot_type":"assistant","is_public":false,"config":{}}')
BOT_ID=$(printf "%s" "$bot_response" | jq -er ".data.id")

key_response=$(curl -fsS -X POST "$API_BASE/bots/$BOT_ID/keys" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  --data '{"name":"task-runtime-smoke"}')
BOT_KEY=$(printf "%s" "$key_response" | jq -er ".data.key")

create_runtime_task() {
  curl -fsS -X POST "$API_BASE/bot-runtime/tasks" \
    -H "Content-Type: application/json" \
    -H "X-Bot-Key: $BOT_KEY" \
    --data "$1"
}

task_response=$(create_runtime_task "{\"title\":\"Bot-created smoke task\",\"description\":\"Disposable bot visibility verification\",\"priority\":\"high\",\"assignee_bot_id\":\"$BOT_ID\",\"latest_status_note\":\"Created by bot runtime smoke test\"}")
task_id=$(printf "%s" "$task_response" | jq -er ".data.id")
TASK_IDS+=("$task_id")
printf "%s" "$task_response" | jq -e --arg bot "$BOT_ID" \
  '.data.events[0].actor_type == "bot" and .data.events[0].actor_id == $bot and .data.assignee_bot_id == $bot' >/dev/null

owner_tasks=$(curl -fsS "$API_BASE/tasks" -H "Authorization: Bearer $TOKEN")
printf "%s" "$owner_tasks" | jq -e --arg task "$task_id" 'any(.data[]; .id == $task)' >/dev/null

runtime_tasks=$(curl -fsS "$API_BASE/bot-runtime/tasks" -H "X-Bot-Key: $BOT_KEY")
printf "%s" "$runtime_tasks" | jq -e --arg task "$task_id" 'any(.data[]; .id == $task)' >/dev/null

progress_response=$(curl -fsS -X POST "$API_BASE/bot-runtime/tasks/$task_id/progress" \
  -H "Content-Type: application/json" \
  -H "X-Bot-Key: $BOT_KEY" \
  --data '{"progress":35,"latest_status_note":"Bot runtime progress smoke test"}')
printf "%s" "$progress_response" | jq -e '.data.progress == 35 and .data.status == "in_progress"' >/dev/null

complete_response=$(curl -fsS -X POST "$API_BASE/bot-runtime/tasks/$task_id/complete" \
  -H "Content-Type: application/json" \
  -H "X-Bot-Key: $BOT_KEY" \
  --data '{"latest_status_note":"Bot runtime completion smoke test"}')
printf "%s" "$complete_response" | jq -e '.data.progress == 100 and .data.status == "completed"' >/dev/null

prerequisite_response=$(create_runtime_task "{\"title\":\"Dependency prerequisite smoke task\",\"priority\":\"normal\",\"assignee_bot_id\":\"$BOT_ID\"}")
prerequisite_id=$(printf "%s" "$prerequisite_response" | jq -er ".data.id")
TASK_IDS+=("$prerequisite_id")

dependent_response=$(create_runtime_task "{\"title\":\"Dependency unlock smoke task\",\"description\":\"Must survive status-only synchronization\",\"priority\":\"critical\",\"dependency_ids\":[\"$prerequisite_id\"],\"latest_status_note\":\"Preserve this note\"}")
dependent_id=$(printf "%s" "$dependent_response" | jq -er ".data.id")
TASK_IDS+=("$dependent_id")
printf "%s" "$dependent_response" | jq -e '.data.status == "blocked"' >/dev/null

curl -fsS -X POST "$API_BASE/bot-runtime/tasks/$prerequisite_id/complete" \
  -H "Content-Type: application/json" \
  -H "X-Bot-Key: $BOT_KEY" \
  --data '{"latest_status_note":"Unlock dependent smoke task"}' >/dev/null

owner_tasks=$(curl -fsS "$API_BASE/tasks" -H "Authorization: Bearer $TOKEN")
printf "%s" "$owner_tasks" | jq -e --arg task "$dependent_id" \
  'any(.data[]; .id == $task and .title == "Dependency unlock smoke task" and .description == "Must survive status-only synchronization" and .priority == "critical" and .status == "available" and .latest_status_note == "Preserve this note")' >/dev/null

printf "PASS bot runtime tasks create, list, transition, and dependency unlock without field loss\n"
