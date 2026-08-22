#!/usr/bin/env bash

set -euo pipefail

if [[ ! -f .env ]]; then
    echo "Error: .env is missing. Copy .env.example to .env and set WORK_DIR and SEARXNG_SECRET_KEY."
    exit 1
fi

set -a
source .env
set +a

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

if [[ -z "${WORK_DIR:-}" ]]; then
    echo "Error: WORK_DIR is not set. Set it to the absolute path of the workspace to mount."
    exit 1
fi

if [[ ! -d "$WORK_DIR" ]]; then
    echo "Error: WORK_DIR does not exist or is not a directory: $WORK_DIR"
    exit 1
fi

if [[ "${1:-}" != "" && "${1:-}" != "full" ]]; then
    echo "Usage: $0 [full]"
    exit 1
fi

if ! command_exists docker; then
    echo "Error: Docker is not installed. Install Docker Engine or Docker Desktop first."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker daemon is not running or inaccessible."
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
else
    echo "Error: Docker Compose V2 is required."
    exit 1
fi

if ! "${COMPOSE_CMD[@]}" config --quiet; then
    echo "Error: Compose configuration is invalid. Resolve the reported configuration error before starting services."
    exit 1
fi

if [[ -z "${SEARXNG_SECRET_KEY:-}" ]]; then
    echo "Error: SEARXNG_SECRET_KEY is not set. Generate one with: openssl rand -hex 32"
    exit 1
fi

if [[ "$OSTYPE" == darwin* ]]; then
    dir_size_bytes=$(du -sk "$WORK_DIR" | awk '{print $1 * 1024}')
else
    dir_size_bytes=$(du -s --bytes "$WORK_DIR" | awk '{print $1}')
fi
max_size_bytes=$((20 * 1024 * 1024 * 1024))

if [[ "$dir_size_bytes" -gt "$max_size_bytes" ]]; then
    echo "Error: WORK_DIR contains more than 20 GB of data. Use a smaller workspace mount."
    exit 1
fi

if [[ "${1:-}" != "full" ]]; then
    echo "Starting frontend, SearxNG, and Valkey. Run '$0 full' to start the backend as well."
    "${COMPOSE_CMD[@]}" --profile core up -d
    exit 0
fi

backend_port="${BACKEND_PORT:-7777}"
if ! [[ "$backend_port" =~ ^[0-9]+$ ]] || ((backend_port < 1 || backend_port > 65535)); then
    echo "Error: BACKEND_PORT must be an integer from 1 to 65535."
    exit 1
fi

startup_timeout="${BACKEND_STARTUP_TIMEOUT:-300}"
if ! [[ "$startup_timeout" =~ ^[0-9]+$ ]] || ((startup_timeout < 1)); then
    echo "Error: BACKEND_STARTUP_TIMEOUT must be a positive integer."
    exit 1
fi

echo "Starting full deployment. Backend readiness may take several minutes while Chrome and providers initialize."
"${COMPOSE_CMD[@]}" --profile full up -d --build

echo "Waiting for the backend readiness endpoint."
for ((attempt = 1; attempt <= startup_timeout; attempt++)); do
    if curl --fail --silent --show-error "http://127.0.0.1:${backend_port}/health" >/dev/null; then
        echo "Backend is ready at http://127.0.0.1:${backend_port}/health"
        echo "Frontend is available at http://127.0.0.1:3000"
        exit 0
    fi
    sleep 1
done

echo "Error: backend did not become ready within ${startup_timeout} seconds."
"${COMPOSE_CMD[@]}" logs --tail=200 backend
exit 1
