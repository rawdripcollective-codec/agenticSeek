#!/usr/bin/env bash
set -euo pipefail

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.live-integration.yml --profile full)
BACKEND_URL="${BACKEND_TEST_URL:-http://127.0.0.1:${BACKEND_PORT:-7777}}"
WORKSPACE_DIR="${WORK_DIR:-$PWD/.live-browser-search-workspace}"
TEST_LOG_DIR="${TEST_LOG_DIR:-$PWD/.live-browser-search-test-logs}"
RESPONSE_FILE="${RESPONSE_FILE:-$TEST_LOG_DIR/live-browser-query-response.json}"
COMPOSE_LOG_FILE="$TEST_LOG_DIR/compose.log"

if [[ -z "${GOOGLE_API_KEY:-}" ]]; then
  printf 'GOOGLE_API_KEY is required for the live browser and web-search integration test.\n' >&2
  exit 1
fi

export BACKEND_BIND_ADDRESS="${BACKEND_BIND_ADDRESS:-127.0.0.1}"
export FRONTEND_BIND_ADDRESS="${FRONTEND_BIND_ADDRESS:-127.0.0.1}"
export SEARXNG_BIND_ADDRESS="${SEARXNG_BIND_ADDRESS:-127.0.0.1}"
export CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-http://localhost:3000}"
export REACT_APP_BACKEND_URL="${REACT_APP_BACKEND_URL:-http://localhost:7777}"
export SEARXNG_SECRET_KEY="${SEARXNG_SECRET_KEY:-live-browser-search-integration-not-for-production}"
export WORK_DIR="$WORKSPACE_DIR"

mkdir -p "$WORK_DIR" "$TEST_LOG_DIR"

cleanup() {
  local exit_code=$?
  "${COMPOSE[@]}" ps || true
  "${COMPOSE[@]}" logs --no-color >"$COMPOSE_LOG_FILE" 2>&1 || true
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
  printf 'FAIL: live browser backend did not become ready at %s/health\n' "$BACKEND_URL" >&2
  return 1
}

assert_browser_search_path() {
  local backend_log
  backend_log=$("${COMPOSE[@]}" logs --no-color backend)
  if ! grep -Fq 'Selected agent: Browser (roles: web)' <<<"$backend_log"; then
    printf 'FAIL: request did not route to the browser agent\n' >&2
    return 1
  fi
  if ! grep -Fq 'Search results:' <<<"$backend_log"; then
    printf 'FAIL: browser agent did not obtain SearxNG search results\n' >&2
    return 1
  fi
  if ! grep -Fq 'Navigating to ' <<<"$backend_log"; then
    printf 'FAIL: browser agent did not navigate to a public search result\n' >&2
    return 1
  fi
}

printf 'Starting live Gemini browser and web-search Compose test stack...\n'
"${COMPOSE[@]}" up --build --detach --wait --wait-timeout 240
wait_for_ready
printf 'PASS: live browser backend readiness established\n'

metrics=$(curl --silent --show-error --max-time 180 --output "$RESPONSE_FILE" --write-out '%{http_code} %{time_total}' \
  --request POST "$BACKEND_URL/query" \
  --header 'Content-Type: application/json' \
  --data '{"query":"Search the public web for the phrase Example Domains on IANA, visit the official IANA result, and give a concise source-backed summary. Do not log in, submit forms, purchase anything, or browse beyond public informational pages.","tts_enabled":false}')
read -r http_status total_seconds <<<"$metrics"

if [[ "$http_status" != "200" ]]; then
  printf 'FAIL: live browser-agent request returned HTTP %s\n' "$http_status" >&2
  exit 1
fi
if ! grep -Eq '"done"[[:space:]]*:[[:space:]]*"true"' "$RESPONSE_FILE"; then
  printf 'FAIL: live browser-agent response did not report completion\n' >&2
  exit 1
fi
if ! grep -Eq '"success"[[:space:]]*:[[:space:]]*"true"' "$RESPONSE_FILE"; then
  printf 'FAIL: live browser-agent response did not report success\n' >&2
  exit 1
fi
if ! grep -Eq '"agent_name"[[:space:]]*:[[:space:]]*"Browser"' "$RESPONSE_FILE"; then
  printf 'FAIL: live request did not identify Browser as the responding agent\n' >&2
  exit 1
fi
if ! grep -Eq '"answer"[[:space:]]*:[[:space:]]*"[^\"]+"' "$RESPONSE_FILE"; then
  printf 'FAIL: live browser-agent response did not contain an answer\n' >&2
  exit 1
fi
assert_browser_search_path

response_bytes=$(wc -c <"$RESPONSE_FILE")
printf 'PASS: live Gemini browser and web-search request completed in %ss (%s response bytes, response content withheld)\n' "$total_seconds" "$response_bytes"
