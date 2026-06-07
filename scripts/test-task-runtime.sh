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

create_user_task() {
  curl -fsS -X POST "$API_BASE/tasks" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    --data "$1"
}

post_user_task_action() {
  local task_id="$1"
  local action="$2"
  local payload="$3"

  curl -fsS -X POST "$API_BASE/tasks/$task_id/$action" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    --data "$payload"
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

user_task_response=$(create_user_task '{"title":"User-dispatched runtime smoke task","description":"Disposable dispatch/result/review verification","priority":"critical","status":"pending"}')
user_task_id=$(printf "%s" "$user_task_response" | jq -er ".data.id")
TASK_IDS+=("$user_task_id")
printf "%s" "$user_task_response" | jq -e '.data.status == "pending"' >/dev/null

dispatch_response=$(post_user_task_action "$user_task_id" dispatch "{\"assignee_bot_id\":\"$BOT_ID\",\"note\":\"Dispatch from smoke test\"}")
printf "%s" "$dispatch_response" | jq -e --arg bot "$BOT_ID" \
  '.data.status == "claimed" and .data.assignee_bot_id == $bot and (.data.dispatched_at | type == "string") and .data.events[0].event_type == "task.dispatched"' >/dev/null

queue_response=$(curl -fsS "$API_BASE/bot-runtime/tasks/queue" -H "X-Bot-Key: $BOT_KEY")
printf "%s" "$queue_response" | jq -e --arg task "$user_task_id" 'any(.data[]; .id == $task and .status == "claimed")' >/dev/null

claim_response=$(curl -fsS -X POST "$API_BASE/bot-runtime/tasks/$user_task_id/claim" \
  -H "Content-Type: application/json" \
  -H "X-Bot-Key: $BOT_KEY" \
  --data '{"latest_status_note":"Claimed by runtime smoke test"}')
printf "%s" "$claim_response" | jq -e '.data.status == "claimed" and (.data.claimed_at | type == "string")' >/dev/null

progress_response=$(curl -fsS -X POST "$API_BASE/bot-runtime/tasks/$user_task_id/progress" \
  -H "Content-Type: application/json" \
  -H "X-Bot-Key: $BOT_KEY" \
  --data '{"progress":35,"latest_status_note":"Bot runtime progress smoke test"}')
printf "%s" "$progress_response" | jq -e '.data.progress == 35 and .data.status == "in_progress"' >/dev/null

child_response=$(create_runtime_task "{\"title\":\"Bot-created child smoke task\",\"description\":\"Child task spawned during execution\",\"priority\":\"normal\",\"parent_task_id\":\"$user_task_id\",\"latest_status_note\":\"Spawned by runtime smoke test\"}")
child_task_id=$(printf "%s" "$child_response" | jq -er ".data.id")
TASK_IDS+=("$child_task_id")
printf "%s" "$child_response" | jq -e --arg parent "$user_task_id" '.data.parent_task_id == $parent and .data.events[0].payload.parent_task_id == $parent' >/dev/null

result_response=$(curl -fsS -X POST "$API_BASE/bot-runtime/tasks/$user_task_id/result" \
  -H "Content-Type: application/json" \
  -H "X-Bot-Key: $BOT_KEY" \
  --data '{"latest_status_note":"Bot runtime result smoke test","result":{"summary":"smoke result ready","output":{"ok":true},"artifacts":[],"metadata":{"source":"scripts/test-task-runtime.sh"}}}')
printf "%s" "$result_response" | jq -e '.data.progress == 100 and .data.status == "awaiting_review" and .data.result.summary == "smoke result ready" and .data.events[0].event_type == "task.result_submitted"' >/dev/null

owner_tasks=$(curl -fsS "$API_BASE/tasks" -H "Authorization: Bearer $TOKEN")
printf "%s" "$owner_tasks" | jq -e --arg task "$user_task_id" \
  'any(.data[]; .id == $task and .status == "awaiting_review" and .result.summary == "smoke result ready")' >/dev/null
printf "%s" "$owner_tasks" | jq -e --arg child "$child_task_id" --arg parent "$user_task_id" \
  'any(.data[]; .id == $child and .parent_task_id == $parent)' >/dev/null

accept_response=$(post_user_task_action "$user_task_id" accept '{"note":"Accepted by smoke test"}')
printf "%s" "$accept_response" | jq -e '.data.status == "completed" and .data.progress == 100 and (.data.reviewed_at | type == "string") and .data.events[0].event_type == "task.accepted"' >/dev/null

prerequisite_response=$(create_runtime_task "{\"title\":\"Dependency prerequisite smoke task\",\"priority\":\"normal\",\"assignee_bot_id\":\"$BOT_ID\"}")
prerequisite_id=$(printf "%s" "$prerequisite_response" | jq -er ".data.id")
TASK_IDS+=("$prerequisite_id")

dependent_response=$(create_runtime_task "{\"title\":\"Dependency unlock smoke task\",\"description\":\"Must survive status-only synchronization\",\"priority\":\"critical\",\"dependency_ids\":[\"$prerequisite_id\"],\"latest_status_note\":\"Preserve this note\"}")
dependent_id=$(printf "%s" "$dependent_response" | jq -er ".data.id")
TASK_IDS+=("$dependent_id")
printf "%s" "$dependent_response" | jq -e '.data.status == "blocked"' >/dev/null

curl -fsS -X POST "$API_BASE/bot-runtime/tasks/$prerequisite_id/result" \
  -H "Content-Type: application/json" \
  -H "X-Bot-Key: $BOT_KEY" \
  --data '{"latest_status_note":"Unlock dependent smoke task","result":{"summary":"dependency ready"}}' >/dev/null
post_user_task_action "$prerequisite_id" accept '{"note":"Accepted dependency smoke task"}' >/dev/null

owner_tasks=$(curl -fsS "$API_BASE/tasks" -H "Authorization: Bearer $TOKEN")
printf "%s" "$owner_tasks" | jq -e --arg task "$dependent_id" \
  'any(.data[]; .id == $task and .title == "Dependency unlock smoke task" and .description == "Must survive status-only synchronization" and .priority == "critical" and .status == "available" and .latest_status_note == "Preserve this note")' >/dev/null

printf "PASS bot runtime tasks create, dispatch, queue, result review, accept, and dependency unlock without field loss\n"
