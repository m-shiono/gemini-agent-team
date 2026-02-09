#!/bin/bash
# ============================================================
# Gemini Agent Team - Configuration
# ============================================================

# --- Paths / .env ---
export SWARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENV_FILE="${ENV_FILE:-$SWARM_DIR/.env}"
if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ -z "$key" ]] && continue
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            export "$key=$value"
        fi
    done < "$ENV_FILE"
fi

# --- Project ---
export PROJECT_NAME="${PROJECT_NAME:-default}"

# --- Directories ---
export AGENTS_DIR="$SWARM_DIR/agents"
export SCRIPTS_DIR="$SWARM_DIR/scripts"
export PROJECT_DIR="$SWARM_DIR/project/$PROJECT_NAME"
export LOGS_DIR="$SWARM_DIR/logs"

# --- Gemini ---
export GEMINI_API_KEY="${GEMINI_API_KEY:-}"
export GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash}"

# --- Pipeline ---
export MAX_REVIEW_ITERATIONS="${MAX_REVIEW_ITERATIONS:-2}"
export AGENT_TIMEOUT="${AGENT_TIMEOUT:-180}"
export WATCH_POLL_INTERVAL="${WATCH_POLL_INTERVAL:-2}"

# --- Analyst / Discussion ---
export ENABLE_ANALYST="${ENABLE_ANALYST:-true}"
export ENABLE_DISCUSSION="${ENABLE_DISCUSSION:-false}"
export DISCUSSION_ROUNDS="${DISCUSSION_ROUNDS:-1}"
export DISCUSSION_FILE="${DISCUSSION_FILE:-$PROJECT_DIR/DISCUSSION.md}"

# --- Status ---
export STATUS_FILE="$LOGS_DIR/status.log"

# --- tmux ---
export SWARM_SESSION="${SWARM_SESSION:-gemini-agent-team}"
