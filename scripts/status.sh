#!/bin/bash
# ============================================================
# Gemini Agent Team - Status Viewer
# ============================================================
# 最新のステータスと直近の実行サマリを表示する。
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWARM_DIR="$(dirname "$SCRIPT_DIR")"

source "$SWARM_DIR/config.sh"

echo "=== Gemini Agent Team Status ==="
echo ""

if [[ -f "$STATUS_FILE" ]]; then
    python3 - <<'PY' "$STATUS_FILE"
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
print("Status File:", path)
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
else
    echo "Status File: not found ($STATUS_FILE)"
fi

echo ""
echo "=== Latest Run Summary ==="

latest_run=$(ls -dt "$HISTORY_DIR"/run-* 2>/dev/null | head -1 || true)
if [[ -n "$latest_run" ]] && [[ -f "$latest_run/summary.txt" ]]; then
    echo "Run Dir: $latest_run"
    cat "$latest_run/summary.txt"
    if [[ -f "$latest_run/ERROR_REPORT.md" ]]; then
        echo ""
        echo "--- Error Report ---"
        cat "$latest_run/ERROR_REPORT.md"
    fi
else
    echo "No run history found in $HISTORY_DIR"
fi
