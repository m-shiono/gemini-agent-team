#!/bin/bash
# ============================================================
# Gemini Agent Team - Quick Check
# ============================================================
# ローカルで最低限の構文チェックを行う。
# ============================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== Quick Check =="
echo ""

echo "[shell] checking..."
bash -n "$ROOT_DIR/scripts/orchestrator.sh"
bash -n "$ROOT_DIR/scripts/status.sh"
bash -n "$ROOT_DIR/start-agent-team.sh"
bash -n "$ROOT_DIR/config.sh"
echo "shell: OK"

echo "[python] checking..."
python3 - <<'PY' "$ROOT_DIR/scripts/gemini_runner.py"
import ast, sys
path = sys.argv[1]
with open(path, "r") as f:
    ast.parse(f.read())
print("python: OK")
PY

echo ""
echo "Quick Check: PASS"
