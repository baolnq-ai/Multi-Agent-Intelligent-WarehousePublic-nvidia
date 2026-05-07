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

required_ports=(5435 6379 9092 2379 9003 9004 19531 9094 8001 3001 3002)

is_port_in_use() {
	local port="$1"
	ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

assert_ports_available() {
	local busy=()
	for port in "${required_ports[@]}"; do
		if is_port_in_use "$port"; then
			busy+=("$port")
		fi
	done

	if [[ ${#busy[@]} -gt 0 ]]; then
		echo "ERROR: Required ports are already in use: ${busy[*]}"
		echo "Stop conflicting processes or containers, then re-run setup.sh"
		exit 1
	fi
}

echo "Cleaning old compose state..."
"${COMPOSE[@]}" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" down --remove-orphans || true

for c in wosa-timescaledb wosa-redis wosa-kafka wosa-etcd wosa-minio wosa-milvus wosa-backend wosa-frontend wosa-nginx wosa-llm-nim; do
	docker rm -f "$c" >/dev/null 2>&1 || true
done

assert_ports_available

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

wait_http "http://localhost:8001/api/v1/health" "backend health"
wait_http "http://localhost:3001" "frontend"
wait_http "http://localhost:3002" "nginx"

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
LOGIN_RESPONSE="$(curl -sS -X POST "http://localhost:8001/api/v1/auth/login" -H "Content-Type: application/json" -d "$LOGIN_PAYLOAD" || true)"
if ! echo "$LOGIN_RESPONSE" | grep -q '"access_token"'; then
	echo "ERROR: auth login failed"
	echo "Response: $LOGIN_RESPONSE"
	exit 1
fi

CHAT_RESPONSE="$(curl -sS -m 30 -X POST "http://localhost:3002/api/v1/chat" -H "Content-Type: application/json" -d '{"message":"chào bạn","session_id":"setup-smoke","enable_reasoning":false}' || true)"
if ! echo "$CHAT_RESPONSE" | grep -q '"reply"'; then
	echo "ERROR: chat smoke test failed"
	echo "Response: $CHAT_RESPONSE"
	exit 1
fi

echo
echo "All services are up and smoke checks passed."
echo "  Frontend direct: http://localhost:3001"
echo "  Nginx gateway:   http://localhost:3002"
echo "  Backend API:     http://localhost:8001"
echo "  API docs:        http://localhost:8001/docs"
