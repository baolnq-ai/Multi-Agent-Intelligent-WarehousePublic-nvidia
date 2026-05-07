#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/deploy/compose/docker-compose.dev.yaml"
COMPOSE_ENV_FILE="$PROJECT_ROOT/deploy/compose/.env"
ROOT_ENV_FILE="$PROJECT_ROOT/.env"

DEEP_CLEAN=false
if [[ "${1:-}" == "--deep-clean" ]]; then
	DEEP_CLEAN=true
fi

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

if [[ -f "$COMPOSE_ENV_FILE" ]]; then
	set -a
	source <(sed 's/\r$//' "$COMPOSE_ENV_FILE")
	set +a
fi

if [[ -f "$ROOT_ENV_FILE" ]]; then
	set -a
	source <(sed 's/\r$//' "$ROOT_ENV_FILE")
	set +a
fi

project_pid_matches() {
	local pid="$1"
	if [[ ! -r "/proc/$pid/cmdline" ]]; then
		return 1
	fi

	local cmdline
	cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
	if [[ "$cmdline" == *"$PROJECT_ROOT"* ]] || [[ "$cmdline" == *"wosa-"* ]] || [[ "$cmdline" == *"compose-backend"* ]] || [[ "$cmdline" == *"compose-frontend"* ]] || [[ "$cmdline" == *"llama-3.3-nemotron"* ]]; then
		return 0
	fi

	if [[ -r "/proc/$pid/cgroup" ]] && grep -qE 'docker|wosa-' "/proc/$pid/cgroup"; then
		if [[ "$cmdline" == *"python"* ]] || [[ "$cmdline" == *"uvicorn"* ]] || [[ "$cmdline" == *"node"* ]] || [[ "$cmdline" == *"llama"* ]]; then
			return 0
		fi
	fi

	return 1
}

kill_pid_safely() {
	local pid="$1"
	if kill -0 "$pid" >/dev/null 2>&1; then
		kill "$pid" >/dev/null 2>&1 || true
		sleep 0.3
	fi
	if kill -0 "$pid" >/dev/null 2>&1; then
		kill -9 "$pid" >/dev/null 2>&1 || true
	fi
}

should_skip_pid() {
	local pid="$1"

	# Never kill this script process or its direct parent shell.
	if [[ "$pid" -eq "$$" ]] || [[ "$pid" -eq "$PPID" ]]; then
		return 0
	fi

	if [[ -r "/proc/$pid/cmdline" ]]; then
		local cmdline
		cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
		if [[ "$cmdline" == *"scripts/stop.sh"* ]] || [[ "$cmdline" == *"/stop.sh"* ]]; then
			return 0
		fi
	fi

	return 1
}

release_gpu_resources() {
	if ! command -v nvidia-smi >/dev/null 2>&1; then
		return 0
	fi

	echo "Checking project GPU processes..."
	mapfile -t gpu_pids < <(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sed '/^$/d' | sort -u)
	for pid in "${gpu_pids[@]:-}"; do
		if [[ -n "$pid" ]] && project_pid_matches "$pid"; then
			echo "Stopping GPU process PID=$pid"
			kill_pid_safely "$pid"
		fi
	done

	mapfile -t gpu_ids < <(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sed '/^$/d')
	for gpu_id in "${gpu_ids[@]:-}"; do
		nvidia-smi --gpu-reset -i "$gpu_id" >/dev/null 2>&1 || true
	done
}

cleanup_runtime_dirs() {
	rm -rf "$PROJECT_ROOT/.runtime" >/dev/null 2>&1 || true
	find "$PROJECT_ROOT" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
	find "$PROJECT_ROOT" -type d -name '.pytest_cache' -prune -exec rm -rf {} + 2>/dev/null || true
	find "$PROJECT_ROOT" -type d -name '.mypy_cache' -prune -exec rm -rf {} + 2>/dev/null || true
	find "$PROJECT_ROOT" -type d -name '.ruff_cache' -prune -exec rm -rf {} + 2>/dev/null || true
	find "$PROJECT_ROOT" -type f -name '*.pyc' -delete 2>/dev/null || true

	if [[ "$DEEP_CLEAN" == "true" ]]; then
		rm -rf "$PROJECT_ROOT/src/ui/web/node_modules" >/dev/null 2>&1 || true
		rm -rf "$PROJECT_ROOT/src/ui/web/build" >/dev/null 2>&1 || true
		rm -rf "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/temp" "$PROJECT_ROOT/logs" >/dev/null 2>&1 || true
	fi
}

echo "Stopping compose stack and containers..."
"${COMPOSE[@]}" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" down -v --remove-orphans --rmi local || true

for c in wosa-timescaledb wosa-redis wosa-kafka wosa-etcd wosa-minio wosa-milvus wosa-backend wosa-frontend wosa-nginx wosa-llm-nim; do
	docker rm -f "$c" >/dev/null 2>&1 || true
done

echo "Stopping residual local project processes..."
mapfile -t local_pids < <(pgrep -f "$PROJECT_ROOT" || true)
for pid in "${local_pids[@]:-}"; do
	if [[ -n "$pid" ]] && ! should_skip_pid "$pid" && project_pid_matches "$pid"; then
		kill_pid_safely "$pid"
	fi
done

release_gpu_resources

# Remove known compose volumes created by this stack.
mapfile -t stack_volumes < <(docker volume ls --format '{{.Name}}' | grep -E '(kafka_data|nim_cache|nim_models)$' || true)
for volume in "${stack_volumes[@]:-}"; do
	docker volume rm "$volume" >/dev/null 2>&1 || true
done

cleanup_runtime_dirs

# Drop host page cache when permission is available.
if [[ -w /proc/sys/vm/drop_caches ]]; then
	sync
	echo 3 > /proc/sys/vm/drop_caches
	echo "Dropped Linux page cache."
else
	echo "Skip dropping page cache (requires root)."
fi

echo "Done. Stack resources have been released."
if [[ "$DEEP_CLEAN" == "true" ]]; then
	echo "Deep clean enabled: removed node_modules/build/tmp/logs caches."
fi
