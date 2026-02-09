#!/bin/bash
# ============================================================
# Gemini Agent Team - Quick Check
# ============================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== Quick Check =="
echo ""

echo "[shell] checking..."
bash -n "$ROOT_DIR/config.sh"
bash -n "$ROOT_DIR/start-agent-team.sh"
bash -n "$ROOT_DIR/scripts/orchestrator.sh"
bash -n "$ROOT_DIR/scripts/gemini_runner.sh"
bash -n "$ROOT_DIR/scripts/status.sh"
echo "  shell: OK"

echo "[gemini CLI] checking..."
if command -v gemini &>/dev/null; then
    echo "  gemini: OK ($(gemini --version 2>/dev/null || echo 'installed'))"
else
    echo "  gemini: NOT FOUND - npm install -g @google/gemini-cli"
    exit 1
fi

echo "[tmux] checking..."
if command -v tmux &>/dev/null; then
    echo "  tmux: OK"
else
    echo "  tmux: NOT FOUND"
    exit 1
fi

echo ""
echo "Quick Check: PASS"
