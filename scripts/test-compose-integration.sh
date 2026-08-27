#!/usr/bin/env bash
set -euo pipefail

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.integration.yml --profile full)
BACKEND_URL="${BACKEND_TEST_URL:-http://127.0.0.1:${BACKEND_PORT:-7777}}"
FRONTEND_URL="${FRONTEND_TEST_URL:-http://127.0.0.1:${FRONTEND_PORT:-3000}}"
SEARXNG_URL="${SEARXNG_TEST_URL:-http://127.0.0.1:8080}"
WORKSPACE_DIR="${WORK_DIR:-$PWD/.integration-workspace}"
TEST_LOG_DIR="${TEST_LOG_DIR:-$PWD/.integration-test-logs}"

export BACKEND_BIND_ADDRESS="${BACKEND_BIND_ADDRESS:-127.0.0.1}"
export FRONTEND_BIND_ADDRESS="${FRONTEND_BIND_ADDRESS:-127.0.0.1}"
export SEARXNG_BIND_ADDRESS="${SEARXNG_BIND_ADDRESS:-127.0.0.1}"
export CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-http://localhost:3000}"
export REACT_APP_BACKEND_URL="${REACT_APP_BACKEND_URL:-http://localhost:7777}"
export SEARXNG_SECRET_KEY="${SEARXNG_SECRET_KEY:-integration-test-secret-key-not-for-production}"
export WORK_DIR="$WORKSPACE_DIR"

mkdir -p "$WORK_DIR" "$TEST_LOG_DIR"

cleanup() {
  local exit_code=$?
  "${COMPOSE[@]}" ps || true
  "${COMPOSE[@]}" logs --no-color >"$TEST_LOG_DIR/compose.log" 2>&1 || true
  if [[ "${KEEP_INTEGRATION_STACK:-false}" != "true" ]]; then
    "${COMPOSE[@]}" down --volumes --remove-orphans || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

wait_for_json_status() {
  local url=$1
  local expected_status=$2
  local description=$3
  local response

  for _ in $(seq 1 90); do
    if response=$(curl --fail --silent --show-error --max-time 5 "$url" 2>/dev/null); then
      if grep -Fq "\"status\":\"$expected_status\"" <<<"$response"; then
        printf 'PASS: %s\n' "$description"
        return 0
      fi
    fi
    sleep 2
  done

  printf 'FAIL: timed out waiting for %s at %s\n' "$description" "$url" >&2
  return 1
}

assert_http_status() {
  local expected=$1
  local method=$2
  local url=$3
  shift 3
  local actual
  actual=$(curl --silent --show-error --output /tmp/agenticseek-integration-response --write-out '%{http_code}' --request "$method" "$@" "$url")
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s %s returned HTTP %s; expected %s\n' "$method" "$url" "$actual" "$expected" >&2
    cat /tmp/agenticseek-integration-response >&2 || true
    return 1
  fi
  printf 'PASS: %s %s returned HTTP %s\n' "$method" "$url" "$actual"
}

wait_for_http_status() {
  local expected=$1
  local method=$2
  local url=$3
  local description=$4
  shift 4

  for _ in $(seq 1 90); do
    if assert_http_status "$expected" "$method" "$url" "$@" >/dev/null 2>&1; then
      printf 'PASS: %s\n' "$description"
      return 0
    fi
    sleep 2
  done

  printf 'FAIL: timed out waiting for %s at %s\n' "$description" "$url" >&2
  return 1
}

printf 'Starting AgenticSeek Compose integration stack...\n'
"${COMPOSE[@]}" up --build --detach --wait --wait-timeout 240

wait_for_json_status "$BACKEND_URL/healthz" "alive" "backend liveness"
wait_for_json_status "$BACKEND_URL/health" "ready" "backend readiness with deterministic provider"

wait_for_http_status 200 GET "$FRONTEND_URL/" "frontend static service"
wait_for_http_status 200 GET "$SEARXNG_URL/" "SearxNG service"
assert_http_status 200 GET "$BACKEND_URL/is_active"
assert_http_status 409 POST "$BACKEND_URL/stop"
assert_http_status 200 OPTIONS "$BACKEND_URL/query" \
  --header "Origin: http://localhost:3000" \
  --header "Access-Control-Request-Method: POST"

frontend_index=$(curl --fail --silent --show-error "$FRONTEND_URL/")
frontend_bundle_path=$(grep -oE '/static/js/main\.[a-zA-Z0-9_-]+\.js' <<<"$frontend_index" | head -n 1)
if [[ -z "$frontend_bundle_path" ]]; then
  printf 'FAIL: frontend HTML does not reference a production JavaScript bundle\n' >&2
  exit 1
fi
if ! curl --fail --silent --show-error "$FRONTEND_URL$frontend_bundle_path" | grep -Fq "$REACT_APP_BACKEND_URL"; then
  printf 'FAIL: frontend JavaScript bundle does not contain the configured backend endpoint %s\n' "$REACT_APP_BACKEND_URL" >&2
  exit 1
fi
printf 'PASS: frontend bundle is configured for the expected backend endpoint\n'

"${COMPOSE[@]}" exec --no-TTY redis valkey-cli ping | grep -Fxq 'PONG'
printf 'PASS: Valkey responds to PING\n'

"${COMPOSE[@]}" exec --no-TTY backend python -c "import socket; [socket.create_connection((host, port), 5).close() for host, port in [('redis', 6379), ('searxng', 8080)]]"
printf 'PASS: backend can reach Valkey and SearxNG over the Compose network\n'

printf 'PASS: Compose integration suite completed successfully.\n'
