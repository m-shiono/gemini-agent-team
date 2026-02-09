#!/bin/bash
# ============================================================
# Gemini Agent Team - Status Viewer
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWARM_DIR="$(dirname "$SCRIPT_DIR")"
source "$SWARM_DIR/config.sh"

echo "=== Gemini Agent Team Status ==="
echo "Project: $PROJECT_NAME"
echo ""

if [[ -f "$STATUS_FILE" ]]; then
    echo "--- Status Log ---"
    tail -20 "$STATUS_FILE"
else
    echo "Status file not found: $STATUS_FILE"
fi

echo ""
echo "--- Project Files (project/$PROJECT_NAME/) ---"
for f in REQUEST.md REQUIREMENTS.md TASK.md PLAN.md CODE_DRAFT.md REVIEW.md DISCUSSION.md; do
    local_f="$PROJECT_DIR/$f"
    if [[ -f "$local_f" && -s "$local_f" ]]; then
        echo "  ✅ $f ($(wc -l < "$local_f") lines)"
    elif [[ -f "$local_f" ]]; then
        echo "  ⬜ $f (empty)"
    else
        echo "  ❌ $f (missing)"
    fi
done
