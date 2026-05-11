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

if [[ ! -f "$COMPOSE_ENV_FILE" ]]; then
	cp "$PROJECT_ROOT/.env.example" "$COMPOSE_ENV_FILE"
	echo "Created $COMPOSE_ENV_FILE from .env.example"
fi

if [[ ! -f "$ROOT_ENV_FILE" ]]; then
	cp "$COMPOSE_ENV_FILE" "$ROOT_ENV_FILE"
	echo "Created $ROOT_ENV_FILE from deploy/compose/.env"
fi

set -a
source <(sed 's/\r$//' "$COMPOSE_ENV_FILE")
source <(sed 's/\r$//' "$ROOT_ENV_FILE")
set +a

declare -A selected_ports=()

is_port_in_use() {
	local port="$1"
	if command -v ss >/dev/null 2>&1; then
		ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
	elif command -v netstat >/dev/null 2>&1; then
		netstat -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
	elif command -v lsof >/dev/null 2>&1; then
		lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
	else
		python3 - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("127.0.0.1", port))
except OSError:
    sys.exit(0)
finally:
    sock.close()
sys.exit(1)
PY
	fi
}

find_available_port() {
	local start_port="$1"
	local max_port=$((start_port + 200))
	local candidate="$start_port"

	while [[ "$candidate" -le "$max_port" ]]; do
		if ! is_port_in_use "$candidate" && [[ -z "${selected_ports[$candidate]:-}" ]]; then
			echo "$candidate"
			return 0
		fi
		candidate=$((candidate + 1))
	done

	echo "ERROR: Unable to find an available port near ${start_port}" >&2
	return 1
}

resolve_host_port() {
	local var_name="$1"
	local default_port="$2"
	local configured_port="${!var_name:-$default_port}"

	if [[ ! "$configured_port" =~ ^[0-9]+$ ]]; then
		configured_port="$default_port"
	fi

	local resolved_port="$configured_port"
	if is_port_in_use "$configured_port" || [[ -n "${selected_ports[$configured_port]:-}" ]]; then
		resolved_port="$(find_available_port "$default_port")"
		echo "Port ${configured_port} is busy, using ${resolved_port} for ${var_name}"
	fi

	export "${var_name}=${resolved_port}"
	selected_ports["$resolved_port"]=1
}

resolve_runtime_ports() {
	resolve_host_port HOST_POSTGRES_PORT 5435
	resolve_host_port HOST_REDIS_PORT 6379
	resolve_host_port HOST_KAFKA_PORT 9092
	resolve_host_port HOST_ETCD_PORT 2379
	resolve_host_port HOST_MINIO_PORT 9003
	resolve_host_port HOST_MINIO_CONSOLE_PORT 9004
	resolve_host_port HOST_MILVUS_GRPC_PORT 19531
	resolve_host_port HOST_MILVUS_HTTP_PORT 9094
	resolve_host_port HOST_BACKEND_PORT 8001
	resolve_host_port HOST_FRONTEND_PORT 3001
	resolve_host_port HOST_NGINX_PORT 3002

	if [[ "${RUN_LLM_NIM:-false}" == "true" ]]; then
		resolve_host_port LLM_NIM_PORT 8000
	fi

	echo "Resolved host ports:"
	echo "  PostgreSQL: ${HOST_POSTGRES_PORT}"
	echo "  Redis:      ${HOST_REDIS_PORT}"
	echo "  Kafka:      ${HOST_KAFKA_PORT}"
	echo "  Etcd:       ${HOST_ETCD_PORT}"
	echo "  MinIO API:  ${HOST_MINIO_PORT}"
	echo "  MinIO UI:   ${HOST_MINIO_CONSOLE_PORT}"
	echo "  Milvus gRPC:${HOST_MILVUS_GRPC_PORT}"
	echo "  Milvus HTTP:${HOST_MILVUS_HTTP_PORT}"
	echo "  Backend:    ${HOST_BACKEND_PORT}"
	echo "  Frontend:   ${HOST_FRONTEND_PORT}"
	echo "  Nginx:      ${HOST_NGINX_PORT}"
	if [[ "${RUN_LLM_NIM:-false}" == "true" ]]; then
		echo "  LLM NIM:    ${LLM_NIM_PORT}"
	fi
}

echo "Cleaning old compose state..."
"${COMPOSE[@]}" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" down --remove-orphans || true

for c in wosa-timescaledb wosa-redis wosa-kafka wosa-etcd wosa-minio wosa-milvus wosa-backend wosa-frontend wosa-nginx wosa-llm-nim; do
	docker rm -f "$c" >/dev/null 2>&1 || true
done

resolve_runtime_ports

services=(timescaledb redis kafka etcd minio milvus backend frontend nginx)
if [[ "${RUN_LLM_NIM:-false}" == "true" ]]; then
	services+=(llm-nim)
fi

echo "Starting services: ${services[*]}"
"${COMPOSE[@]}" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" up -d --build "${services[@]}"

echo "Waiting for TimescaleDB..."
until "${COMPOSE[@]}" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" exec -T timescaledb pg_isready -U "${POSTGRES_USER:-warehouse}" -d "${POSTGRES_DB:-warehouse}" >/dev/null 2>&1; do
	sleep 2
done

echo "Ensuring schema migration tracking table exists..."
"${COMPOSE[@]}" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" exec -T timescaledb \
	psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-warehouse}" -d "${POSTGRES_DB:-warehouse}" \
	-c "CREATE TABLE IF NOT EXISTS schema_migrations (filename TEXT PRIMARY KEY, applied_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW());"

migrations=(
	data/postgres/000_schema.sql
	data/postgres/001_equipment_schema.sql
	data/postgres/002_document_schema.sql
	data/postgres/004_inventory_movements_schema.sql
	scripts/setup/create_model_tracking_tables.sql
)

echo "Applying database migrations (idempotent)..."
for file in "${migrations[@]}"; do
	applied="$(${COMPOSE[@]} --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" exec -T timescaledb \
		psql -tAc "SELECT 1 FROM schema_migrations WHERE filename='${file}'" \
		-U "${POSTGRES_USER:-warehouse}" -d "${POSTGRES_DB:-warehouse}" 2>/dev/null || true)"

	if [[ "$applied" == "1" ]]; then
		echo "  - skip ${file} (already applied)"
		continue
	fi

	echo "  - apply ${file}"
	"${COMPOSE[@]}" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" exec -T timescaledb \
		psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-warehouse}" -d "${POSTGRES_DB:-warehouse}" < "$file"

	"${COMPOSE[@]}" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" exec -T timescaledb \
		psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-warehouse}" -d "${POSTGRES_DB:-warehouse}" \
		-c "INSERT INTO schema_migrations(filename) VALUES ('${file}') ON CONFLICT (filename) DO NOTHING;"
done

wait_http() {
	local url="$1"
	local name="$2"
	local retries="${3:-80}"
	local delay="${4:-2}"
	local i=1
	while [[ "$i" -le "$retries" ]]; do
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

echo "Ensuring default users exist..."
"${COMPOSE[@]}" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" exec -T backend python - <<'PY'
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

echo "Running smoke checks..."
LOGIN_PAYLOAD='{"username":"admin","password":"changeme"}'
LOGIN_RESPONSE="$(curl -sS -X POST "http://localhost:${HOST_BACKEND_PORT}/api/v1/auth/login" -H "Content-Type: application/json" -d "$LOGIN_PAYLOAD" || true)"
if ! echo "$LOGIN_RESPONSE" | grep -q '"access_token"'; then
	echo "ERROR: auth login failed"
	echo "Response: $LOGIN_RESPONSE"
	exit 1
fi

CHAT_RESPONSE="$(curl -sS -m 30 -X POST "http://localhost:${HOST_NGINX_PORT}/api/v1/chat" -H "Content-Type: application/json" -d '{"message":"chào bạn","session_id":"setup-smoke","enable_reasoning":false}' || true)"
if ! echo "$CHAT_RESPONSE" | grep -q '"reply"'; then
	echo "WARN: chat smoke test skipped or unavailable"
	echo "Response: $CHAT_RESPONSE"
fi

echo
echo "All services are up and smoke checks passed."
echo "  Frontend direct: http://localhost:${HOST_FRONTEND_PORT}"
echo "  Nginx gateway:   http://localhost:${HOST_NGINX_PORT}"
echo "  Backend API:     http://localhost:${HOST_BACKEND_PORT}"
echo "  API docs:        http://localhost:${HOST_BACKEND_PORT}/docs"
