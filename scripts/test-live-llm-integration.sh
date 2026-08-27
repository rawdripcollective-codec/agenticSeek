#!/usr/bin/env bash
set -euo pipefail

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.live-integration.yml --profile full)
BACKEND_URL="${BACKEND_TEST_URL:-http://127.0.0.1:${BACKEND_PORT:-7777}}"
WORKSPACE_DIR="${WORK_DIR:-$PWD/.live-integration-workspace}"
TEST_LOG_DIR="${TEST_LOG_DIR:-$PWD/.live-integration-test-logs}"
RESPONSE_FILE="${RESPONSE_FILE:-$TEST_LOG_DIR/live-query-response.json}"

if [[ -z "${GOOGLE_API_KEY:-}" ]]; then
  printf 'GOOGLE_API_KEY is required for the live provider integration test.\n' >&2
  exit 1
fi

export BACKEND_BIND_ADDRESS="${BACKEND_BIND_ADDRESS:-127.0.0.1}"
export FRONTEND_BIND_ADDRESS="${FRONTEND_BIND_ADDRESS:-127.0.0.1}"
export SEARXNG_BIND_ADDRESS="${SEARXNG_BIND_ADDRESS:-127.0.0.1}"
export CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-http://localhost:3000}"
export REACT_APP_BACKEND_URL="${REACT_APP_BACKEND_URL:-http://localhost:7777}"
export SEARXNG_SECRET_KEY="${SEARXNG_SECRET_KEY:-live-integration-secret-key-not-for-production}"
export WORK_DIR="$WORKSPACE_DIR"

mkdir -p "$WORK_DIR" "$TEST_LOG_DIR"

cleanup() {
  local exit_code=$?
  "${COMPOSE[@]}" ps || true
  "${COMPOSE[@]}" logs --no-color >"$TEST_LOG_DIR/compose.log" 2>&1 || true
  if [[ "${KEEP_LIVE_INTEGRATION_STACK:-false}" != "true" ]]; then
    "${COMPOSE[@]}" down --volumes --remove-orphans || true
  fi
  rm -f "$RESPONSE_FILE"
  exit "$exit_code"
}
trap cleanup EXIT

wait_for_ready() {
  local response
  for _ in $(seq 1 90); do
    if response=$(curl --fail --silent --show-error --max-time 5 "$BACKEND_URL/health" 2>/dev/null); then
      if grep -Fq '"status":"ready"' <<<"$response"; then
        return 0
      fi
    fi
    sleep 2
  done
  printf 'FAIL: live-provider backend did not become ready at %s/health\n' "$BACKEND_URL" >&2
  return 1
}

printf 'Starting live-provider Compose test stack...\n'
"${COMPOSE[@]}" up --build --detach --wait --wait-timeout 240
wait_for_ready
printf 'PASS: live-provider backend readiness established\n'

metrics=$(curl --silent --show-error --max-time 120 --output "$RESPONSE_FILE" --write-out '%{http_code} %{time_total}' \
  --request POST "$BACKEND_URL/query" \
  --header 'Content-Type: application/json' \
  --data '{"query":"hi","tts_enabled":false}')
read -r http_status total_seconds <<<"$metrics"

if [[ "$http_status" != "200" ]]; then
  printf 'FAIL: live agent request returned HTTP %s\n' "$http_status" >&2
  exit 1
fi
if ! grep -Eq '"done"[[:space:]]*:[[:space:]]*"true"' "$RESPONSE_FILE"; then
  printf 'FAIL: live agent response did not report completion\n' >&2
  exit 1
fi
if ! grep -Eq '"success"[[:space:]]*:[[:space:]]*"true"' "$RESPONSE_FILE"; then
  printf 'FAIL: live agent response did not report success\n' >&2
  exit 1
fi
if ! grep -Eq '"answer"[[:space:]]*:[[:space:]]*"[^\"]+"' "$RESPONSE_FILE"; then
  printf 'FAIL: live agent response did not contain an answer\n' >&2
  exit 1
fi

answer_bytes=$(wc -c <"$RESPONSE_FILE")
printf 'PASS: live Gemini conversational-agent request completed in %ss (%s response bytes, response content withheld)\n' "$total_seconds" "$answer_bytes"
