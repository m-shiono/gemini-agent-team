#!/bin/bash
# ============================================================
# Gemini Agent Team - Configuration
# ============================================================

# --- Paths / .env ---
export SWARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENV_FILE="${ENV_FILE:-$SWARM_DIR/.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

export AGENTS_DIR="$SWARM_DIR/agents"
export SCRIPTS_DIR="$SWARM_DIR/scripts"
export SHARED_DIR="$SWARM_DIR/shared"
export LOGS_DIR="$SWARM_DIR/logs"

# --- Gemini Authentication ---
# 認証モードを選択してください:
#   auto      : 自動判定（APIキー/Vertex AI/ADC を順に検出）
#   api_key   : Google AI Studio の API キーを使用
#   vertex_ai : Google Cloud Vertex AI を使用（gcloud 認証）
#   adc       : Application Default Credentials を使用（gcloud auth application-default login）
export GEMINI_AUTH_MODE="${GEMINI_AUTH_MODE:-auto}"

# [api_key モード] API キーを設定
export GEMINI_API_KEY="${GEMINI_API_KEY:-}"

# [vertex_ai モード] Google Cloud プロジェクト設定
export GEMINI_GCP_PROJECT="${GEMINI_GCP_PROJECT:-}"
export GEMINI_GCP_LOCATION="${GEMINI_GCP_LOCATION:-us-central1}"

# [adc モード] 任意: サービスアカウントのJSONを使う場合
export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-}"

# --- Gemini Model ---
export GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash}"

# --- Pipeline Settings ---
# Reviewer がNGを出した場合の Engineer 再実行の最大回数
export MAX_REVIEW_ITERATIONS="${MAX_REVIEW_ITERATIONS:-2}"
# 各エージェントのタイムアウト（秒）
export AGENT_TIMEOUT="${AGENT_TIMEOUT:-180}"
# 監視の安定化設定（ファイル書き込みの完了待ち）
export TASK_DEBOUNCE_SECONDS="${TASK_DEBOUNCE_SECONDS:-0.5}"
export TASK_STABLE_CHECKS="${TASK_STABLE_CHECKS:-2}"
export TASK_STABLE_INTERVAL="${TASK_STABLE_INTERVAL:-0.5}"
# 監視ポーリング間隔（inotify 非対応時）
export WATCH_POLL_INTERVAL="${WATCH_POLL_INTERVAL:-2}"

# Analyst / Discussion
export ENABLE_ANALYST="${ENABLE_ANALYST:-true}"
export ENABLE_DISCUSSION="${ENABLE_DISCUSSION:-false}"
export DISCUSSION_ROUNDS="${DISCUSSION_ROUNDS:-1}"
export DISCUSSION_FILE="${DISCUSSION_FILE:-$SHARED_DIR/DISCUSSION.md}"

# タスクキュー（自動取得）
export ENABLE_TASK_QUEUE="${ENABLE_TASK_QUEUE:-false}"
export TASK_QUEUE_DIR="${TASK_QUEUE_DIR:-$SWARM_DIR/tasks/inbox}"
export TASK_QUEUE_PATTERN="${TASK_QUEUE_PATTERN:-*.md}"
export TASK_QUEUE_PRIORITY_REGEX="${TASK_QUEUE_PRIORITY_REGEX:-^P([0-9])_}"
export TASK_QUEUE_DEFAULT_PRIORITY="${TASK_QUEUE_DEFAULT_PRIORITY:-5}"
export TASK_QUEUE_YAML_PRIORITY_KEY="${TASK_QUEUE_YAML_PRIORITY_KEY:-priority}"
export TASK_QUEUE_YAML_TITLE_KEY="${TASK_QUEUE_YAML_TITLE_KEY:-title}"
export TASK_QUEUE_YAML_OWNER_KEY="${TASK_QUEUE_YAML_OWNER_KEY:-owner}"
export TASK_QUEUE_YAML_DUE_KEY="${TASK_QUEUE_YAML_DUE_KEY:-due}"
export TASK_QUEUE_OWNER_FILTER="${TASK_QUEUE_OWNER_FILTER:-}"
export TASK_QUEUE_DUE_WARN_DAYS="${TASK_QUEUE_DUE_WARN_DAYS:-0}"
export TASK_QUEUE_OWNER_PRIORITY_BIAS="${TASK_QUEUE_OWNER_PRIORITY_BIAS:-}"  # 例: alice=-1,bob=1
export TASK_QUEUE_DUE_FORMATS="${TASK_QUEUE_DUE_FORMATS:-%Y-%m-%d,%Y-%m-%d %H:%M}"
export TASK_QUEUE_DUE_TZ="${TASK_QUEUE_DUE_TZ:-local}"  # local | +09:00 など
export TASK_QUEUE_OWNER_SUBDIR="${TASK_QUEUE_OWNER_SUBDIR:-false}"
export TASK_QUEUE_DUE_WARN_HOURS="${TASK_QUEUE_DUE_WARN_HOURS:-0}"
export TASK_QUEUE_OWNER_AUTO_DIR="${TASK_QUEUE_OWNER_AUTO_DIR:-true}"
export TASK_QUEUE_DUE_LABEL_PREFIX="${TASK_QUEUE_DUE_LABEL_PREFIX:-DUE_}"
export TASK_QUEUE_OVERDUE_ACTION="${TASK_QUEUE_OVERDUE_ACTION:-warn}"  # warn | fail
export WEBHOOK_NOTIFY_OVERDUE="${WEBHOOK_NOTIFY_OVERDUE:-false}"
export WEBHOOK_OVERDUE_URL="${WEBHOOK_OVERDUE_URL:-}"
export TASK_QUEUE_OVERDUE_REQUEUE="${TASK_QUEUE_OVERDUE_REQUEUE:-false}"
export TASK_QUEUE_INPROGRESS_DIR="${TASK_QUEUE_INPROGRESS_DIR:-$SWARM_DIR/tasks/in-progress}"
export TASK_QUEUE_DONE_DIR="${TASK_QUEUE_DONE_DIR:-$SWARM_DIR/tasks/done}"
export TASK_QUEUE_FAILED_DIR="${TASK_QUEUE_FAILED_DIR:-$SWARM_DIR/tasks/failed}"
export TASK_QUEUE_REQUEUE_ON_FAILURE="${TASK_QUEUE_REQUEUE_ON_FAILURE:-false}"
export TASK_QUEUE_RETRY_MAX="${TASK_QUEUE_RETRY_MAX:-3}"
export TASK_QUEUE_RETRY_BACKOFF_BASE="${TASK_QUEUE_RETRY_BACKOFF_BASE:-30}"

# タスク完了時のサマリ通知
export WEBHOOK_INCLUDE_SUMMARY="${WEBHOOK_INCLUDE_SUMMARY:-true}"
export TASK_SUMMARY_MAX_CHARS="${TASK_SUMMARY_MAX_CHARS:-280}"

# 二重起動防止ロック
export SWARM_LOCK_FILE="${SWARM_LOCK_FILE:-$LOGS_DIR/agent-team.lock}"

# 実行履歴の保存
export HISTORY_DIR="${HISTORY_DIR:-$LOGS_DIR/runs}"
export KEEP_RUNS="${KEEP_RUNS:-20}"

# パイプライン失敗時の再試行
export PIPELINE_RETRY_COUNT="${PIPELINE_RETRY_COUNT:-1}"
export PIPELINE_RETRY_DELAY="${PIPELINE_RETRY_DELAY:-3}"


# ログ/履歴のマスキング
# 例: export REDACT_VALUES="your-secret,another-secret"
export REDACT_VALUES="${REDACT_VALUES:-${GEMINI_API_KEY:-}}"
export REDACT_REPLACEMENT="${REDACT_REPLACEMENT:-[REDACTED]}"

# Webhook 通知（任意）
export WEBHOOK_URL="${WEBHOOK_URL:-}"
export WEBHOOK_TIMEOUT="${WEBHOOK_TIMEOUT:-5}"
export WEBHOOK_INCLUDE_TASK="${WEBHOOK_INCLUDE_TASK:-false}"
export WEBHOOK_TEMPLATE="${WEBHOOK_TEMPLATE:-generic}"   # generic | slack | discord | teams | teams_adaptive
export WEBHOOK_OWNER_MAP="${WEBHOOK_OWNER_MAP:-}"        # 例: alice=https://...,bob=https://...

# セキュリティ
export UMASK_VALUE="${UMASK_VALUE:-077}"
export SECURE_FILES="${SECURE_FILES:-true}"
export TASK_SECRET_ALLOW="${TASK_SECRET_ALLOW:-false}"
export TASK_SECRET_REGEX="${TASK_SECRET_REGEX:-AIza[0-9A-Za-z\\-_]{20,}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN PRIVATE KEY-----}"

# 運用
export STATUS_FILE="${STATUS_FILE:-$LOGS_DIR/status.json}"
export MAINTENANCE_MODE="${MAINTENANCE_MODE:-false}"

# --- tmux Settings ---
export SWARM_SESSION="${SWARM_SESSION:-gemini-agent-team}"
