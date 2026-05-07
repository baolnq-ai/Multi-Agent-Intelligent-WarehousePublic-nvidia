#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/scripts/run_all_services.sh"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
	echo "ERROR: missing startup script: $TARGET_SCRIPT" >&2
	exit 1
fi

if [[ ! -x "$TARGET_SCRIPT" ]]; then
	chmod +x "$TARGET_SCRIPT" 2>/dev/null || true
fi

echo "[setup] Starting project services from repository root..."
exec "$TARGET_SCRIPT" "$@"
