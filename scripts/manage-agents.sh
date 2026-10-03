#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONTAINER_REPO_ROOT="/workspace"
GENERATED_ENV_DIR="$SCRIPT_DIR/.managed-agents"
DEFAULT_CONFIG_FILE="$SCRIPT_DIR/agents.conf"
DEFAULT_BASE_ENV_FILE="$SCRIPT_DIR/test-agent.env"
TEST_AGENT_PREFIX="test-agent"
TEST_AGENT_IMAGE="${TEST_AGENT_IMAGE:-node:22}"
TEST_AGENT_WORKDIR="/workspace"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

CONFIG_FILE="$DEFAULT_CONFIG_FILE"
BASE_ENV_FILE="$DEFAULT_BASE_ENV_FILE"
TARGET=""
SINGLE_ENV_FILE=""

declare -A CONFIGURED_AGENT_ENV_FILES=()
declare -A SEEN_AGENT_NAMES=()

usage() {
  cat <<EOF
Usage:
  ./scripts/manage-agents.sh list [--config FILE]
  ./scripts/manage-agents.sh start <name|all> [--env-file FILE] [--config FILE] [--base-env FILE]
  ./scripts/manage-agents.sh stop <name|all> [--config FILE]
  ./scripts/manage-agents.sh restart <name|all> [--env-file FILE] [--config FILE] [--base-env FILE]
  ./scripts/manage-agents.sh status <name|all> [--config FILE]

Examples:
  ./scripts/manage-agents.sh list
  ./scripts/manage-agents.sh start alpha
  ./scripts/manage-agents.sh start beta --env-file scripts/agents/beta.env
  ./scripts/manage-agents.sh restart all
  ./scripts/manage-agents.sh stop all

Config file format:
  scripts/agents.conf
  Each non-comment line is:
    <name> [env-file]
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_docker_access() {
  if ! docker info >/dev/null 2>&1; then
    die "docker daemon is not accessible. Check that Docker is running and your user can access /var/run/docker.sock."
  fi
}

resolve_path() {
  local base_dir="$1"
  local raw_path="$2"

  if [[ "$raw_path" == /* ]]; then
    printf '%s\n' "$raw_path"
    return 0
  fi

  printf '%s/%s\n' "$base_dir" "$raw_path"
}

container_path_for_host_file() {
  local host_path="$1"

  case "$host_path" in
    "$REPO_ROOT"/*)
      printf '%s%s\n' "$CONTAINER_REPO_ROOT" "${host_path#"$REPO_ROOT"}"
      ;;
    *)
      die "path must stay inside repository: $host_path"
      ;;
  esac
}

quote_shell() {
  printf '%q' "$1"
}

validate_agent_name() {
  local name="$1"

  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    die "invalid agent name '$name' (expected [a-z0-9][a-z0-9-]*)"
  fi
}

container_name_for() {
  printf '%s-%s\n' "$TEST_AGENT_PREFIX" "$1"
}

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

container_is_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

container_status() {
  local container_name="$1"
  local status

  status="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || true)"
  if [[ -n "$status" ]]; then
    printf '%s\n' "$status"
  else
    printf 'missing\n'
  fi
}

configured_env_file_for() {
  local name="$1"

  if [[ -n "${CONFIGURED_AGENT_ENV_FILES[$name]:-}" ]]; then
    printf '%s\n' "${CONFIGURED_AGENT_ENV_FILES[$name]}"
  fi
}

load_config() {
  local config_path="$1"
  local config_dir
  local line
  local line_no=0
  local stripped
  local name
  local env_file
  local extra

  CONFIGURED_AGENT_ENV_FILES=()

  if [[ ! -f "$config_path" ]]; then
    return 0
  fi

  config_dir="$(cd -- "$(dirname -- "$config_path")" && pwd)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    stripped="${line%%#*}"
    if [[ -z "${stripped//[[:space:]]/}" ]]; then
      continue
    fi

    name=""
    env_file=""
    extra=""
    read -r name env_file extra <<<"$stripped"

    [[ -n "$name" ]] || continue
    validate_agent_name "$name"
    if [[ -n "$extra" ]]; then
      die "invalid config entry at $config_path:$line_no"
    fi

    if [[ -z "$env_file" ]]; then
      env_file="$config_dir/agents/$name.env"
    else
      env_file="$(resolve_path "$config_dir" "$env_file")"
    fi

    CONFIGURED_AGENT_ENV_FILES["$name"]="$env_file"
  done <"$config_path"
}

active_agent_names() {
  local name

  while IFS= read -r name; do
    if [[ "$name" == "$TEST_AGENT_PREFIX"-* ]]; then
      printf '%s\n' "${name#"$TEST_AGENT_PREFIX"-}"
    fi
  done < <(docker ps -a --format '{{.Names}}')
}

ensure_unique_name() {
  local name="$1"

  if [[ -z "${SEEN_AGENT_NAMES[$name]:-}" ]]; then
    printf '%s\n' "$name"
    SEEN_AGENT_NAMES["$name"]=1
  fi
}

collect_names_from_config() {
  local name

  for name in "${!CONFIGURED_AGENT_ENV_FILES[@]}"; do
    ensure_unique_name "$name" >/dev/null
  done
}

collect_names_from_active_containers() {
  local name

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    ensure_unique_name "$name" >/dev/null
  done < <(active_agent_names)
}

resolve_target_names() {
  local target="$1"
  local include_active="${2:-false}"
  local allow_empty="${3:-false}"
  local names=()
  local name

  SEEN_AGENT_NAMES=()

  if [[ "$target" == "all" ]]; then
    collect_names_from_config
    if [[ "$include_active" == "true" ]]; then
      collect_names_from_active_containers
    fi
    for name in "${!SEEN_AGENT_NAMES[@]}"; do
      names+=("$name")
    done
    if [[ "${#names[@]}" -eq 0 ]]; then
      if [[ "$allow_empty" == "true" ]]; then
        return 0
      fi
      die "no agents found in $CONFIG_FILE"
    fi
    printf '%s\n' "${names[@]}" | sort
    return 0
  fi

  validate_agent_name "$target"
  printf '%s\n' "$target"
}

parse_args() {
  if [[ "$COMMAND" == "list" || "$COMMAND" == "help" || "$COMMAND" == "--help" || "$COMMAND" == "-h" ]]; then
    TARGET=""
  else
    TARGET="${1:-all}"
    if [[ $# -gt 0 ]]; then
      shift
    fi
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "--config requires a file path"
        CONFIG_FILE="$(resolve_path "$PWD" "$2")"
        shift 2
        ;;
      --env-file)
        [[ $# -ge 2 ]] || die "--env-file requires a file path"
        SINGLE_ENV_FILE="$(resolve_path "$PWD" "$2")"
        shift 2
        ;;
      --base-env)
        [[ $# -ge 2 ]] || die "--base-env requires a file path"
        BASE_ENV_FILE="$(resolve_path "$PWD" "$2")"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  CONFIG_FILE="$(resolve_path "$PWD" "$CONFIG_FILE")"
  BASE_ENV_FILE="$(resolve_path "$PWD" "$BASE_ENV_FILE")"
}

resolve_env_file_for_agent() {
  local name="$1"

  if [[ -n "$SINGLE_ENV_FILE" ]]; then
    if [[ "$TARGET" == "all" ]]; then
      die "--env-file can only be used with a single agent"
    fi
    printf '%s\n' "$SINGLE_ENV_FILE"
    return 0
  fi

  configured_env_file_for "$name"
}

write_generated_env() {
  local name="$1"
  local agent_env_file="$2"
  local host_generated_file
  local container_base_env
  local container_agent_env
  local state_dir
  local log_dir
  local config_path

  [[ -f "$BASE_ENV_FILE" ]] || die "missing base env file: $BASE_ENV_FILE"
  if [[ -n "$agent_env_file" && ! -f "$agent_env_file" ]]; then
    die "missing agent env file for '$name': $agent_env_file"
  fi

  mkdir -p "$GENERATED_ENV_DIR"
  host_generated_file="$GENERATED_ENV_DIR/$name.env"
  container_base_env="$(container_path_for_host_file "$BASE_ENV_FILE")"
  state_dir="test/openclaw-bot-chat/data/test-agent/$name"
  log_dir="$state_dir/logs"
  config_path="test/openclaw-bot-chat/.test-agent.$name.config.json"

  {
    printf '# Auto-generated by scripts/manage-agents.sh for %s\n' "$name"
    printf 'source %s\n' "$(quote_shell "$container_base_env")"
    if [[ -n "$agent_env_file" ]]; then
      container_agent_env="$(container_path_for_host_file "$agent_env_file")"
      printf 'source %s\n' "$(quote_shell "$container_agent_env")"
    fi
    printf ': "${BOT_CHAT_TEST_AGENT_KEY:=%s}"\n' "$(quote_shell "$name")"
    printf ': "${BOT_CHAT_TEST_AGENT_STATE_DIR:=%s}"\n' "$(quote_shell "$state_dir")"
    printf ': "${BOT_CHAT_TEST_AGENT_LOG_DIR:=%s}"\n' "$(quote_shell "$log_dir")"
    printf ': "${BOT_CHAT_TEST_AGENT_CONFIG:=%s}"\n' "$(quote_shell "$config_path")"
  } >"$host_generated_file"

  printf '%s\n' "$host_generated_file"
}

ensure_runtime_stack() {
  load_env_file
  compose up -d --wait backend >/dev/null
}

start_agent() {
  local name="$1"
  local container_name
  local agent_env_file
  local generated_env_file
  local container_generated_env_file

  container_name="$(container_name_for "$name")"
  if container_is_running "$container_name"; then
    echo "$container_name is already running."
    return 0
  fi

  if container_exists "$container_name"; then
    docker rm -f "$container_name" >/dev/null
  fi

  agent_env_file="$(resolve_env_file_for_agent "$name")"
  generated_env_file="$(write_generated_env "$name" "$agent_env_file")"
  container_generated_env_file="$(container_path_for_host_file "$generated_env_file")"

  ensure_runtime_stack
  docker run -d --name "$container_name" \
    --workdir "$TEST_AGENT_WORKDIR" \
    --mount "type=bind,src=$REPO_ROOT,dst=$TEST_AGENT_WORKDIR" \
    --network host \
    -e "BOT_CHAT_TEST_AGENT_ENV=$container_generated_env_file" \
    "$TEST_AGENT_IMAGE" \
    bash -lc "./scripts/test-agent.sh start" >/dev/null

  echo "Started $container_name"
}

stop_agent() {
  local name="$1"
  local container_name

  container_name="$(container_name_for "$name")"
  if container_exists "$container_name"; then
    docker rm -f "$container_name" >/dev/null
    echo "Stopped $container_name"
  else
    echo "$container_name is not running."
  fi
}

print_agent_status() {
  local name="$1"
  local container_name
  local env_file

  container_name="$(container_name_for "$name")"
  env_file="$(resolve_env_file_for_agent "$name")"
  printf '%-24s %-10s %s\n' "$container_name" "$(container_status "$container_name")" "${env_file:-<base env only>}"
}

run_list() {
  local any=0
  local name

  require_docker_access
  load_config "$CONFIG_FILE"
  echo "CONTAINER                 STATUS     ENV FILE"

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    any=1
    print_agent_status "$name"
  done < <(resolve_target_names all true true)

  if [[ "$any" -eq 0 ]]; then
    echo "No configured or running test agents."
  fi
}

run_start() {
  local name

  require_docker_access
  load_config "$CONFIG_FILE"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    start_agent "$name"
  done < <(resolve_target_names "${TARGET:-all}")
}

run_stop() {
  local name

  require_docker_access
  load_config "$CONFIG_FILE"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    stop_agent "$name"
  done < <(resolve_target_names "${TARGET:-all}" true)
}

run_restart() {
  local name

  require_docker_access
  load_config "$CONFIG_FILE"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    stop_agent "$name" >/dev/null
    start_agent "$name"
  done < <(resolve_target_names "${TARGET:-all}" true)
}

run_status() {
  local name

  require_docker_access
  load_config "$CONFIG_FILE"
  echo "CONTAINER                 STATUS     ENV FILE"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    print_agent_status "$name"
  done < <(resolve_target_names "${TARGET:-all}" true true)
}

main() {
  parse_args "$@"

  case "$COMMAND" in
    list)
      run_list
      ;;
    start)
      run_start
      ;;
    stop)
      run_stop
      ;;
    restart)
      run_restart
      ;;
    status)
      run_status
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage
      die "unknown command: $COMMAND"
      ;;
  esac
}

main "$@"
