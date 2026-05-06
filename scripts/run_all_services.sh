#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/deploy/compose/docker-compose.dev.yaml"
COMPOSE_ENV_FILE="$PROJECT_ROOT/deploy/compose/.env"
ROOT_ENV_FILE="$PROJECT_ROOT/.env"

cd "$PROJECT_ROOT"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is required"
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
else
  echo "ERROR: docker compose plugin is required"
  exit 1
fi

if [ ! -f "$COMPOSE_ENV_FILE" ]; then
  cp "$PROJECT_ROOT/.env.example" "$COMPOSE_ENV_FILE"
  echo "Created $COMPOSE_ENV_FILE from .env.example"
fi

if [ ! -f "$ROOT_ENV_FILE" ]; then
  cp "$COMPOSE_ENV_FILE" "$ROOT_ENV_FILE"
  echo "Created $ROOT_ENV_FILE from deploy/compose/.env"
fi

set -a
source <(sed 's/\r$//' "$COMPOSE_ENV_FILE")
set +a

is_port_in_use() {
  local port="$1"
  ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

find_free_port() {
  local candidate="$1"
  while is_port_in_use "$candidate"; do
    candidate=$((candidate + 1))
  done
  echo "$candidate"
}

choose_port_into() {
  local var_name="$1"
  local default_port="$2"
  local selected="$default_port"
  if is_port_in_use "$selected" || [[ " ${RESERVED_PORTS[*]} " == *" ${selected} "* ]]; then
    selected="$(find_free_port $((default_port + 1)))"
  fi
  while [[ " ${RESERVED_PORTS[*]} " == *" ${selected} "* ]]; do
    selected=$((selected + 1))
    while is_port_in_use "$selected"; do
      selected=$((selected + 1))
    done
  done
  RESERVED_PORTS+=("$selected")
  printf -v "$var_name" '%s' "$selected"
}

RESERVED_PORTS=()

choose_port_into HOST_POSTGRES_PORT 5435
choose_port_into HOST_REDIS_PORT 6379
choose_port_into HOST_KAFKA_PORT 9092
choose_port_into HOST_ETCD_PORT 2379
choose_port_into HOST_MINIO_PORT 9000
choose_port_into HOST_MINIO_CONSOLE_PORT 9001
choose_port_into HOST_MILVUS_GRPC_PORT 19530
choose_port_into HOST_MILVUS_HTTP_PORT 9091
choose_port_into HOST_BACKEND_PORT 8001
choose_port_into HOST_FRONTEND_PORT 3001
choose_port_into HOST_NGINX_PORT 3000

export HOST_POSTGRES_PORT
export HOST_REDIS_PORT
export HOST_KAFKA_PORT
export HOST_ETCD_PORT
export HOST_MINIO_PORT
export HOST_MINIO_CONSOLE_PORT
export HOST_MILVUS_GRPC_PORT
export HOST_MILVUS_HTTP_PORT
export HOST_BACKEND_PORT
export HOST_FRONTEND_PORT
export HOST_NGINX_PORT

if [ "${HOST_POSTGRES_PORT}" != "5435" ]; then
  export PGPORT="$HOST_POSTGRES_PORT"
fi

services=(timescaledb redis kafka etcd minio milvus backend frontend nginx)
if [ "${RUN_LLM_NIM:-false}" = "true" ]; then
  services+=(llm-nim)
fi

echo "Using host ports:"
echo "  postgres=${HOST_POSTGRES_PORT} redis=${HOST_REDIS_PORT} kafka=${HOST_KAFKA_PORT} etcd=${HOST_ETCD_PORT}"
echo "  minio=${HOST_MINIO_PORT} minio_console=${HOST_MINIO_CONSOLE_PORT}"
echo "  milvus_grpc=${HOST_MILVUS_GRPC_PORT} milvus_http=${HOST_MILVUS_HTTP_PORT}"
echo "  backend=${HOST_BACKEND_PORT} frontend=${HOST_FRONTEND_PORT} nginx=${HOST_NGINX_PORT}"

echo "Cleaning previous compose state..."
"${COMPOSE[@]}" -f "$COMPOSE_FILE" down --remove-orphans || true

# Hard cleanup for stale named containers left by interrupted runs.
for c in wosa-timescaledb wosa-redis wosa-kafka wosa-etcd wosa-minio wosa-milvus wosa-backend wosa-frontend wosa-nginx wosa-llm-nim; do
  docker rm -f "$c" >/dev/null 2>&1 || true
done

echo "Starting services: ${services[*]}"
"${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d --build "${services[@]}"

echo "Waiting for TimescaleDB..."
until "${COMPOSE[@]}" -f "$COMPOSE_FILE" exec -T timescaledb pg_isready -U "${POSTGRES_USER:-warehouse}" -d "${POSTGRES_DB:-warehouse}" >/dev/null 2>&1; do
  sleep 2
done

migrations=(
  data/postgres/000_schema.sql
  data/postgres/001_equipment_schema.sql
  data/postgres/002_document_schema.sql
  data/postgres/004_inventory_movements_schema.sql
  scripts/setup/create_model_tracking_tables.sql
)

echo "Running SQL migrations..."
for file in "${migrations[@]}"; do
  echo "  applying $file"
  "${COMPOSE[@]}" -f "$COMPOSE_FILE" exec -T timescaledb psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-warehouse}" -d "${POSTGRES_DB:-warehouse}" < "$file"
done

echo "Creating default admin and user accounts..."
"${COMPOSE[@]}" -f "$COMPOSE_FILE" exec -T backend python - <<'PY'
import asyncio
import os
import asyncpg
import bcrypt

async def main():
    conn = await asyncpg.connect(
        host=os.getenv("DB_HOST", "timescaledb"),
        port=int(os.getenv("DB_PORT", "5432")),
        user=os.getenv("POSTGRES_USER", "warehouse"),
        password=os.getenv("POSTGRES_PASSWORD", "changeme"),
        database=os.getenv("POSTGRES_DB", "warehouse"),
    )

    async def upsert_user(username, email, full_name, role, password_env, default_password):
        password = os.getenv(password_env, default_password).encode("utf-8")
        if len(password) > 72:
            password = password[:72]
        hashed = bcrypt.hashpw(password, bcrypt.gensalt()).decode("utf-8")

        exists = await conn.fetchval("SELECT EXISTS(SELECT 1 FROM users WHERE username=$1)", username)
        if exists:
            await conn.execute(
                "UPDATE users SET hashed_password=$1, status='active', updated_at=NOW() WHERE username=$2",
                hashed,
                username,
            )
        else:
            await conn.execute(
                "INSERT INTO users (username, email, full_name, role, status, hashed_password) VALUES ($1,$2,$3,$4,'active',$5)",
                username,
                email,
                full_name,
                role,
                hashed,
            )

    await upsert_user("admin", "admin@warehouse.com", "System Administrator", "admin", "DEFAULT_ADMIN_PASSWORD", "changeme")
    await upsert_user("user", "user@warehouse.com", "Regular User", "operator", "DEFAULT_USER_PASSWORD", "changeme")
    await conn.close()

asyncio.run(main())
print("Default users are ready")
PY

wait_http() {
  local url="$1"
  local name="$2"
  local retries="${3:-60}"
  local delay="${4:-2}"
  local i=1
  while [ "$i" -le "$retries" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "OK: $name"
      return 0
    fi
    sleep "$delay"
    i=$((i + 1))
  done
  echo "ERROR: $name did not become ready at $url"
  return 1
}

wait_http "http://localhost:${HOST_BACKEND_PORT}/api/v1/health" "backend health"
wait_http "http://localhost:${HOST_FRONTEND_PORT}" "frontend"
wait_http "http://localhost:${HOST_NGINX_PORT}" "nginx"

wait_backend_db_healthy() {
  local retries="${1:-60}"
  local delay="${2:-2}"
  local i=1
  while [ "$i" -le "$retries" ]; do
    local health
    health="$(curl -sS "http://localhost:${HOST_BACKEND_PORT}/api/v1/health" || true)"
    if echo "$health" | grep -Eq '"database"[[:space:]]*:[[:space:]]*\{[^}]*"status"[[:space:]]*:[[:space:]]*"healthy"'; then
      echo "OK: backend database connectivity"
      return 0
    fi
    sleep "$delay"
    i=$((i + 1))
  done
  echo "ERROR: backend database service did not become healthy"
  curl -sS "http://localhost:${HOST_BACKEND_PORT}/api/v1/health" || true
  return 1
}

wait_backend_db_healthy

echo "Verifying login flow..."
LOGIN_PAYLOAD='{"username":"admin","password":"changeme"}'
LOGIN_RESPONSE=""
for _ in $(seq 1 20); do
  LOGIN_RESPONSE="$(curl -sS -X POST "http://localhost:${HOST_BACKEND_PORT}/api/v1/auth/login" -H "Content-Type: application/json" -d "$LOGIN_PAYLOAD" || true)"
  if echo "$LOGIN_RESPONSE" | grep -q '"access_token"'; then
    echo "OK: auth login"
    break
  fi
  sleep 2
done

if ! echo "$LOGIN_RESPONSE" | grep -q '"access_token"'; then
  echo "ERROR: auth login failed"
  echo "Response: $LOGIN_RESPONSE"
  exit 1
fi

echo
echo "All services started and smoke tests passed."
echo "Frontend direct:  http://localhost:${HOST_FRONTEND_PORT}"
echo "Nginx gateway:    http://localhost:${HOST_NGINX_PORT}"
echo "Backend API:      http://localhost:${HOST_BACKEND_PORT}"
echo "API docs:         http://localhost:${HOST_BACKEND_PORT}/docs"

echo
echo "Useful commands:"
echo "  docker compose -f $COMPOSE_FILE ps"
echo "  docker compose -f $COMPOSE_FILE logs -f backend"
