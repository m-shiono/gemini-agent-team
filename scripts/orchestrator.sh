#!/bin/bash
# ============================================================
# Gemini Agent Team Orchestrator
# ============================================================
# エージェントパイプラインを管理する中央制御スクリプト。
#
# 改善点（元の仕様から）:
# - ファイル監視チェーンではなく中央オーケストレータが制御
# - md5sum でコンテンツハッシュを確実に比較
# - inotifywait 対応（フォールバック: ポーリング）
# - レビューフィードバックループ
# - エラーハンドリング
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWARM_DIR="$(dirname "$SCRIPT_DIR")"

# 設定の読み込み
source "$SWARM_DIR/config.sh"

# セキュアなデフォルト権限
umask "${UMASK_VALUE:-077}"

# ============================================================
# ユーティリティ関数
# ============================================================

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info() {
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅ $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ❌ $1${NC}"
}

log_agent() {
    local agent="$1"
    local msg="$2"
    local icon="$3"
    echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} ${icon} ${BOLD}[${agent}]${NC} ${msg}"
}

log_divider() {
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ファイルのハッシュを取得
get_file_hash() {
    local file="$1"
    if [[ -f "$file" ]] && [[ -s "$file" ]]; then
        md5sum "$file" 2>/dev/null | cut -d' ' -f1
    else
        echo ""
    fi
}

# ファイルが安定するまで待機（連続で同じハッシュになるまで）
wait_for_stable_file() {
    local file="$1"
    local checks="${TASK_STABLE_CHECKS:-2}"
    local interval="${TASK_STABLE_INTERVAL:-0.5}"

    if [[ ! -f "$file" ]] || [[ ! -s "$file" ]]; then
        return 1
    fi

    local last_hash=""
    local stable_count=0

    while true; do
        local current_hash
        current_hash=$(get_file_hash "$file")

        if [[ -n "$current_hash" && "$current_hash" == "$last_hash" ]]; then
            stable_count=$((stable_count + 1))
        else
            stable_count=0
            last_hash="$current_hash"
        fi

        if [[ $stable_count -ge $checks ]]; then
            return 0
        fi

        sleep "$interval"
    done
}

# タスクキューから次のタスクを取得
pick_next_task() {
    if [[ "${ENABLE_TASK_QUEUE:-false}" != "true" ]]; then
        return 1
    fi

    mkdir -p "$TASK_QUEUE_DIR" \
        "$TASK_QUEUE_INPROGRESS_DIR" "$TASK_QUEUE_DONE_DIR" "$TASK_QUEUE_FAILED_DIR"
    if [[ "${TASK_QUEUE_OWNER_SUBDIR:-false}" == "true" ]] && \
       [[ "${TASK_QUEUE_OWNER_AUTO_DIR:-true}" == "true" ]] && \
       [[ -n "${TASK_QUEUE_OWNER_FILTER:-}" ]]; then
        mkdir -p "$TASK_QUEUE_DIR/${TASK_QUEUE_OWNER_FILTER}"
    fi

    local next
    next=$(python3 - <<'PY' \
"$TASK_QUEUE_DIR" "$TASK_QUEUE_PATTERN" \
"${TASK_QUEUE_PRIORITY_REGEX:-^P([0-9])_}" "${TASK_QUEUE_DEFAULT_PRIORITY:-5}" \
"${TASK_QUEUE_YAML_PRIORITY_KEY:-priority}" "${TASK_QUEUE_YAML_TITLE_KEY:-title}" \
"${TASK_QUEUE_YAML_OWNER_KEY:-owner}" "${TASK_QUEUE_OWNER_FILTER:-}" \
"${TASK_QUEUE_OWNER_SUBDIR:-false}"
import os, re, sys, glob
queue_dir, pattern, regex, default_priority, priority_key, title_key, owner_key, owner_filter, owner_subdir = sys.argv[1:10]
default_priority = int(default_priority)

paths = glob.glob(os.path.join(queue_dir, pattern))
if owner_filter and str(owner_subdir).lower() == "true":
    paths += glob.glob(os.path.join(queue_dir, owner_filter, pattern))
if not paths:
    print("")
    raise SystemExit(0)

priority_re = re.compile(regex)
time_re = re.compile(r'^T(\d+)_')
retry_re = re.compile(r'\.r(\d+)(\.|$)')

def parse_front_matter(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            first = f.readline().strip()
            if first != "---":
                return {}
            data = {}
            for line in f:
                line = line.strip()
                if line == "---":
                    break
                if ":" in line:
                    key, val = line.split(":", 1)
                    data[key.strip()] = val.strip().strip('"').strip("'")
            return data
    except Exception:
        return {}

def priority(path):
    meta = parse_front_matter(path)
    if priority_key in meta:
        try:
            return int(meta[priority_key])
        except Exception:
            pass
    name = os.path.basename(path)
    m = priority_re.search(name)
    if not m:
        return default_priority
    try:
        return int(m.group(1))
    except Exception:
        return default_priority

def available_at(path):
    name = os.path.basename(path)
    m = time_re.search(name)
    if not m:
        return 0
    try:
        return int(m.group(1))
    except Exception:
        return 0

def retry_count(path):
    name = os.path.basename(path)
    m = retry_re.search(name)
    if not m:
        return 0
    try:
        return int(m.group(1))
    except Exception:
        return 0

def owner_ok(path):
    if not owner_filter:
        return True
    meta = parse_front_matter(path)
    return meta.get(owner_key, "") == owner_filter

def owner_bias(path):
    if not owner_filter:
        pass
    meta = parse_front_matter(path)
    owner = meta.get(owner_key, "")
    if not owner or not os.environ.get("TASK_QUEUE_OWNER_PRIORITY_BIAS"):
        return 0
    raw = os.environ.get("TASK_QUEUE_OWNER_PRIORITY_BIAS", "")
    items = [i.strip() for i in raw.split(",") if i.strip()]
    for item in items:
        if "=" not in item:
            continue
        k, v = item.split("=", 1)
        if k.strip() == owner:
            try:
                return int(v.strip())
            except Exception:
                return 0
    return 0

# 優先度が低い数ほど優先。次に最終更新時刻が古いものを優先。
now = int(os.path.getmtime(queue_dir))  # fallback
try:
    import time
    now = int(time.time())
except Exception:
    pass

eligible = [p for p in paths if available_at(p) <= now and owner_ok(p)]
if not eligible:
    print("")
    raise SystemExit(0)

eligible.sort(key=lambda p: (priority(p) + owner_bias(p), os.path.getmtime(p), retry_count(p)))
print(eligible[0])
PY
)
    if [[ -z "$next" ]]; then
        return 1
    fi

    local base
    base=$(basename "$next")
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local inprogress="$TASK_QUEUE_INPROGRESS_DIR/$base.$ts"

    log_info "📥 タスクキューから取得: $base"
    mv "$next" "$inprogress"
    cp "$inprogress" "$SHARED_DIR/TASK.md"

    CURRENT_TASK_PATH="$inprogress"
    CURRENT_TASK_BASENAME="$base"
    TASK_SOURCE="queue"

    CURRENT_TASK_PRIORITY=$(python3 - <<'PY' "$inprogress" "${TASK_QUEUE_YAML_PRIORITY_KEY:-priority}" "${TASK_QUEUE_PRIORITY_REGEX:-^P([0-9])_}" "${TASK_QUEUE_DEFAULT_PRIORITY:-5}"
import re, sys
path, key, regex, default_priority = sys.argv[1:5]
default_priority = int(default_priority)
priority_re = re.compile(regex)
def parse_front_matter(p):
    try:
        with open(p, "r", encoding="utf-8", errors="ignore") as f:
            first = f.readline().strip()
            if first != "---":
                return {}
            data = {}
            for line in f:
                line = line.strip()
                if line == "---":
                    break
                if ":" in line:
                    k, v = line.split(":", 1)
                    data[k.strip()] = v.strip().strip('"').strip("'")
            return data
    except Exception:
        return {}
meta = parse_front_matter(path)
if key in meta:
    try:
        print(int(meta[key]))
        raise SystemExit(0)
    except Exception:
        pass
m = priority_re.search(path.split("/")[-1])
if m:
    try:
        print(int(m.group(1)))
        raise SystemExit(0)
    except Exception:
        pass
print(default_priority)
PY
)

    CURRENT_TASK_TITLE=$(python3 - <<'PY' "$inprogress" "${TASK_QUEUE_YAML_TITLE_KEY:-title}"
import sys
path, key = sys.argv[1:3]
def parse_front_matter(p):
    try:
        with open(p, "r", encoding="utf-8", errors="ignore") as f:
            first = f.readline().strip()
            if first != "---":
                return {}
            data = {}
            for line in f:
                line = line.strip()
                if line == "---":
                    break
                if ":" in line:
                    k, v = line.split(":", 1)
                    data[k.strip()] = v.strip().strip('"').strip("'")
            return data
    except Exception:
        return {}
meta = parse_front_matter(path)
print(meta.get(key, ""))
PY
)

    CURRENT_TASK_OWNER=$(python3 - <<'PY' "$inprogress" "${TASK_QUEUE_YAML_OWNER_KEY:-owner}"
import sys
path, key = sys.argv[1:3]
def parse_front_matter(p):
    try:
        with open(p, "r", encoding="utf-8", errors="ignore") as f:
            first = f.readline().strip()
            if first != "---":
                return {}
            data = {}
            for line in f:
                line = line.strip()
                if line == "---":
                    break
                if ":" in line:
                    k, v = line.split(":", 1)
                    data[k.strip()] = v.strip().strip('"').strip("'")
            return data
    except Exception:
        return {}
meta = parse_front_matter(path)
print(meta.get(key, ""))
PY
)

    CURRENT_TASK_DUE=$(python3 - <<'PY' "$inprogress" "${TASK_QUEUE_YAML_DUE_KEY:-due}"
import sys
path, key = sys.argv[1:3]
def parse_front_matter(p):
    try:
        with open(p, "r", encoding="utf-8", errors="ignore") as f:
            first = f.readline().strip()
            if first != "---":
                return {}
            data = {}
            for line in f:
                line = line.strip()
                if line == "---":
                    break
                if ":" in line:
                    k, v = line.split(":", 1)
                    data[k.strip()] = v.strip().strip('"').strip("'")
            return data
    except Exception:
        return {}
meta = parse_front_matter(path)
print(meta.get(key, ""))
PY
)

    CURRENT_TASK_RETRY=$(python3 - <<'PY' "$inprogress"
import re, sys
path = sys.argv[1]
name = path.split("/")[-1]
m = re.search(r'\\.r(\\d+)(\\.|$)', name)
if not m:
    print(0)
else:
    try:
        print(int(m.group(1)))
    except Exception:
        print(0)
PY
)

    if [[ -n "$CURRENT_TASK_TITLE" ]]; then
        log_info "   └─ title: $CURRENT_TASK_TITLE (P${CURRENT_TASK_PRIORITY})"
        update_status "queue" "PICKED" "P${CURRENT_TASK_PRIORITY} ${CURRENT_TASK_TITLE}"
    else
        log_info "   └─ priority: P${CURRENT_TASK_PRIORITY}"
        update_status "queue" "PICKED" "P${CURRENT_TASK_PRIORITY}"
    fi

    if [[ -n "$CURRENT_TASK_OWNER" ]]; then
        update_status "queue_owner" "INFO" "$CURRENT_TASK_OWNER"
    fi
    if [[ -n "$CURRENT_TASK_DUE" ]]; then
        update_status "queue_due" "INFO" "$CURRENT_TASK_DUE"
        local due_flag
        due_flag=$(python3 - <<'PY' "$CURRENT_TASK_DUE" "${TASK_QUEUE_DUE_WARN_DAYS:-0}" "${TASK_QUEUE_DUE_WARN_HOURS:-0}" "${TASK_QUEUE_DUE_FORMATS:-%Y-%m-%d,%Y-%m-%d %H:%M}" "${TASK_QUEUE_DUE_TZ:-local}"
import sys
from datetime import datetime, date, timezone, timedelta
due_str, warn_days, warn_hours, formats, due_tz = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
fmts = [f.strip() for f in formats.split(",") if f.strip()]
def parse_due(s):
    for f in fmts:
        try:
            return datetime.strptime(s, f)
        except Exception:
            pass
    return None
dt = parse_due(due_str)
if dt:
    if dt.tzinfo is None and due_tz and due_tz != "local":
        try:
            sign = 1 if due_tz[0] == "+" else -1
            hh, mm = due_tz[1:].split(":")
            offset = timedelta(hours=int(hh) * sign, minutes=int(mm) * sign)
            dt = dt.replace(tzinfo=timezone(offset))
        except Exception:
            pass
    now = datetime.now(dt.tzinfo) if dt.tzinfo else datetime.now()
    today = now.date()
    due_date = dt.date()
    if due_date < today:
        print("OVERDUE")
    else:
        if warn_days > 0 and (due_date - today).days <= warn_days:
            print("DUE_SOON")
        elif warn_hours > 0:
            diff_hours = (dt - now).total_seconds() / 3600.0
            if 0 <= diff_hours <= warn_hours:
                print("DUE_SOON")
PY
)
        if [[ -n "$due_flag" ]]; then
            local due_label="${TASK_QUEUE_DUE_LABEL_PREFIX:-DUE_}${due_flag}"
            log_info "⚠️  due: $CURRENT_TASK_DUE ($due_flag)"
            update_status "queue_due_status" "WARN" "$due_flag"
            update_status "queue_due_label" "INFO" "$due_label"
            if [[ "$due_flag" == "OVERDUE" ]]; then
                if [[ "${WEBHOOK_NOTIFY_OVERDUE:-true}" == "true" ]]; then
                    notify_overdue "0"
                fi
            fi
            if [[ "$due_flag" == "OVERDUE" ]] && [[ "${TASK_QUEUE_OVERDUE_ACTION:-warn}" == "fail" ]]; then
                log_error "期限超過のためタスクを失敗扱いにします"
                append_error_report "QUEUE" "Overdue task blocked"
                update_status "queue_due_action" "FAILED" "overdue"
                if should_finalize_task; then
                    if [[ "${TASK_QUEUE_OVERDUE_REQUEUE:-false}" == "true" ]]; then
                        finalize_task_status "failed"
                    else
                        finalize_task_status "failed" "true"
                    fi
                fi
                return 0
            fi
        fi
    fi
    if [[ -n "$CURRENT_TASK_RETRY" ]]; then
        update_status "queue_retry" "INFO" "$CURRENT_TASK_RETRY"
    fi
    return 0
}

# タスクの状態を更新（キュー起動時のみ）
finalize_task_status() {
    local status="$1"  # done | failed
    local norequeue="${2:-false}"
    if [[ "${TASK_SOURCE:-manual}" != "queue" ]]; then
        return 0
    fi
    if [[ -z "${CURRENT_TASK_PATH:-}" ]] || [[ ! -f "$CURRENT_TASK_PATH" ]]; then
        return 0
    fi

    local ts
    ts=$(date '+%Y%m%d-%H%M%S')

    if [[ "$status" == "done" ]]; then
        mv "$CURRENT_TASK_PATH" "$TASK_QUEUE_DONE_DIR/${CURRENT_TASK_BASENAME}.${ts}"
    else
        if [[ "${TASK_QUEUE_REQUEUE_ON_FAILURE:-false}" == "true" && "$norequeue" != "true" ]]; then
            local max_retry="${TASK_QUEUE_RETRY_MAX:-3}"
            local backoff_base="${TASK_QUEUE_RETRY_BACKOFF_BASE:-30}"
            local current_retry="${CURRENT_TASK_RETRY:-0}"

            if [[ "$current_retry" -lt "$max_retry" ]]; then
                local next_retry=$((current_retry + 1))
                local delay=$((backoff_base * (2 ** (next_retry - 1))))
                local now
                now=$(date +%s)
                local available_at=$((now + delay))
                local requeue_name="T${available_at}_${CURRENT_TASK_BASENAME}.r${next_retry}"
                mv "$CURRENT_TASK_PATH" "$TASK_QUEUE_DIR/$requeue_name"
                log_info "♻️  タスクを再投入: $requeue_name (delay=${delay}s)"
            else
                mv "$CURRENT_TASK_PATH" "$TASK_QUEUE_FAILED_DIR/${CURRENT_TASK_BASENAME}.${ts}"
                if [[ -f "$RUN_DIR/ERROR_REPORT.md" ]]; then
                    cp "$RUN_DIR/ERROR_REPORT.md" "$TASK_QUEUE_FAILED_DIR/${CURRENT_TASK_BASENAME}.${ts}.reason.md" 2>/dev/null || true
                fi
            fi
        else
            mv "$CURRENT_TASK_PATH" "$TASK_QUEUE_FAILED_DIR/${CURRENT_TASK_BASENAME}.${ts}"
            if [[ -f "$RUN_DIR/ERROR_REPORT.md" ]]; then
                cp "$RUN_DIR/ERROR_REPORT.md" "$TASK_QUEUE_FAILED_DIR/${CURRENT_TASK_BASENAME}.${ts}.reason.md" 2>/dev/null || true
            fi
        fi
    fi

    CURRENT_TASK_PATH=""
    CURRENT_TASK_BASENAME=""
    TASK_SOURCE="manual"
}

should_finalize_task() {
    local attempt="${PIPELINE_ATTEMPT:-1}"
    local total="${PIPELINE_TOTAL:-1}"
    if [[ "$attempt" -lt "$total" ]]; then
        return 1
    fi
    return 0
}
# エージェント出力を DISCUSSION に追記するためのヘルパ
run_agent_append() {
    local agent_name="$1"
    local role_file="$2"
    local output_file="$3"
    shift 3
    local input_files=("$@")

    local tmp_out="$RUN_DIR/${agent_name}_discussion.md"
    if run_agent "$agent_name" "$role_file" "$tmp_out" "${input_files[@]}"; then
        {
            echo "## ${agent_name^^}"
            echo ""
            cat "$tmp_out"
            echo ""
        } >> "$output_file"
        return 0
    fi
    return 1
}
# 実行IDと履歴保存の準備
init_run_context() {
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    RUN_ID="${ts}-$$"
    RUN_DIR="$HISTORY_DIR/run-${RUN_ID}"
    mkdir -p "$RUN_DIR"
}

save_artifact() {
    local label="$1"
    local src="$2"
    if [[ -f "$src" ]] && [[ -s "$src" ]]; then
        redact_copy "$src" "$RUN_DIR/${label}.md"
    fi
}

redact_copy() {
    local src="$1"
    local dest="$2"
    local replacement="${REDACT_REPLACEMENT:-[REDACTED]}"

    if [[ ! -f "$src" ]]; then
        return 1
    fi

    if [[ -z "${REDACT_VALUES:-}" ]]; then
        cp "$src" "$dest"
        return 0
    fi

    python3 - <<'PY' "$src" "$dest" "$replacement" "${REDACT_VALUES:-}"
import sys
src, dest, replacement, values = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(src, "r", encoding="utf-8", errors="ignore") as f:
    data = f.read()
for val in [v.strip() for v in values.split(",") if v.strip()]:
    data = data.replace(val, replacement)
with open(dest, "w", encoding="utf-8") as f:
    f.write(data)
PY
}

write_run_summary() {
    local status="$1"
    local elapsed="$2"
    {
        echo "run_id: $RUN_ID"
        echo "status: $status"
        echo "elapsed_seconds: $elapsed"
        echo "started_at: $RUN_START_TIME"
        echo "ended_at: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "task_first_line: $(head -1 "$SHARED_DIR/TASK.md" 2>/dev/null)"
    } > "$RUN_DIR/summary.txt"
}

get_webhook_url() {
    local owner="${1:-}"
    local map="${WEBHOOK_OWNER_MAP:-}"
    if [[ -n "$owner" && -n "$map" ]]; then
        IFS=',' read -r -a pairs <<< "$map"
        for pair in "${pairs[@]}"; do
            if [[ "$pair" == *"="* ]]; then
                local key="${pair%%=*}"
                local val="${pair#*=}"
                if [[ "$key" == "$owner" ]]; then
                    echo "$val"
                    return 0
                fi
            fi
        done
    fi
    echo "${WEBHOOK_URL:-}"
}

get_overdue_webhook_url() {
    if [[ -n "${WEBHOOK_OVERDUE_URL:-}" ]]; then
        echo "${WEBHOOK_OVERDUE_URL}"
        return 0
    fi
    get_webhook_url "${CURRENT_TASK_OWNER:-}"
}

notify_overdue() {
    local elapsed="${1:-0}"
    local url
    url=$(get_overdue_webhook_url)
    if [[ -z "$url" ]]; then
        return 0
    fi
    # OVERDUE は summary なしで送信
    notify_webhook "OVERDUE" "$elapsed" ""
}

notify_webhook() {
    local status="$1"
    local elapsed="$2"
    local summary="${3:-}"
    local url
    url=$(get_webhook_url "${CURRENT_TASK_OWNER:-}")
    if [[ -z "$url" ]]; then
        return 0
    fi

    if ! command -v curl &>/dev/null; then
        log_info "⚠️  curl が見つからないためWebhook通知をスキップします"
        return 0
    fi

    local include_task="${WEBHOOK_INCLUDE_TASK:-false}"
    local task_first=""
    if [[ "$include_task" == "true" ]]; then
        task_first="$(head -1 "$SHARED_DIR/TASK.md" 2>/dev/null)"
    fi

    local template="${WEBHOOK_TEMPLATE:-generic}"
    local payload
    payload=$(python3 - <<'PY' "$status" "$elapsed" "$RUN_ID" "$RUN_DIR" "$task_first" "$template" "$summary" "${WEBHOOK_INCLUDE_SUMMARY:-true}" "${TASK_SUMMARY_MAX_CHARS:-280}" "${CURRENT_TASK_TITLE:-}" "${CURRENT_TASK_OWNER:-}" "${CURRENT_TASK_DUE:-}"
import json, sys
status, elapsed, run_id, run_dir, task_first, template, summary, include_summary, max_chars, task_title, task_owner, task_due = sys.argv[1:13]
include_summary = str(include_summary).lower() == "true"
try:
    max_chars = int(max_chars)
except Exception:
    max_chars = 280
data = {
    "status": status,
    "elapsed_seconds": int(elapsed),
    "run_id": run_id,
    "run_dir": run_dir,
}
if task_first:
    data["task_first_line"] = task_first
if task_title:
    data["task_title"] = task_title
if task_owner:
    data["task_owner"] = task_owner
if task_due:
    data["task_due"] = task_due
if include_summary and summary:
    if len(summary) > max_chars:
        summary = summary[:max_chars] + "..."
    data["summary"] = summary

def to_slack(payload):
    text = f"Gemini Agent Team: {payload['status']} (elapsed {payload['elapsed_seconds']}s)"
    fields = [
        {"title": "run_id", "value": payload.get("run_id", "-"), "short": True},
        {"title": "elapsed", "value": f\"{payload.get('elapsed_seconds', 0)}s\", "short": True},
    ]
    if "task_first_line" in payload:
        fields.append({"title": "task", "value": payload["task_first_line"], "short": False})
    if "task_title" in payload:
        fields.append({"title": "title", "value": payload["task_title"], "short": False})
    if "task_owner" in payload:
        fields.append({"title": "owner", "value": payload["task_owner"], "short": True})
    if "task_due" in payload:
        fields.append({"title": "due", "value": payload["task_due"], "short": True})
    if "summary" in payload:
        fields.append({"title": "summary", "value": payload["summary"], "short": False})
    return {
        "text": text,
        "attachments": [{
            "color": "#36a64f" if payload.get("status") == "SUCCESS" else "#e3b341",
            "fields": fields,
        }]
    }

def to_discord(payload):
    color = 0x2ECC71 if payload.get("status") == "SUCCESS" else 0xF1C40F
    embed = {
        "title": f"Gemini Agent Team: {payload.get('status')}",
        "color": color,
        "fields": [
            {"name": "run_id", "value": payload.get("run_id", "-"), "inline": True},
            {"name": "elapsed", "value": f\"{payload.get('elapsed_seconds', 0)}s\", "inline": True},
        ],
    }
    if "task_first_line" in payload:
        embed["fields"].append({"name": "task", "value": payload["task_first_line"], "inline": False})
    if "task_title" in payload:
        embed["fields"].append({"name": "title", "value": payload["task_title"], "inline": False})
    if "task_owner" in payload:
        embed["fields"].append({"name": "owner", "value": payload["task_owner"], "inline": True})
    if "task_due" in payload:
        embed["fields"].append({"name": "due", "value": payload["task_due"], "inline": True})
    if "summary" in payload:
        embed["fields"].append({"name": "summary", "value": payload["summary"], "inline": False})
    return {"embeds": [embed]}

def to_teams(payload):
    color = "00A65A" if payload.get("status") == "SUCCESS" else "F1C40F"
    facts = [
        {"name": "run_id", "value": payload.get("run_id", "-")},
        {"name": "elapsed", "value": f"{payload.get('elapsed_seconds', 0)}s"},
    ]
    if "task_first_line" in payload:
        facts.append({"name": "task", "value": payload["task_first_line"]})
    if "task_title" in payload:
        facts.append({"name": "title", "value": payload["task_title"]})
    if "task_owner" in payload:
        facts.append({"name": "owner", "value": payload["task_owner"]})
    if "task_due" in payload:
        facts.append({"name": "due", "value": payload["task_due"]})
    if "summary" in payload:
        facts.append({"name": "summary", "value": payload["summary"]})
    return {
        "@type": "MessageCard",
        "@context": "http://schema.org/extensions",
        "summary": f"Gemini Agent Team: {payload.get('status')}",
        "themeColor": color,
        "title": f"Gemini Agent Team: {payload.get('status')}",
        "sections": [{"facts": facts}],
    }

def to_teams_adaptive(payload):
    status = payload.get("status", "-")
    color = "Good" if status == "SUCCESS" else "Warning"
    facts = [
        {"title": "run_id", "value": payload.get("run_id", "-")},
        {"title": "elapsed", "value": f"{payload.get('elapsed_seconds', 0)}s"},
    ]
    if "task_first_line" in payload:
        facts.append({"title": "task", "value": payload["task_first_line"]})
    if "task_title" in payload:
        facts.append({"title": "title", "value": payload["task_title"]})
    if "task_owner" in payload:
        facts.append({"title": "owner", "value": payload["task_owner"]})
    if "task_due" in payload:
        facts.append({"title": "due", "value": payload["task_due"]})
    if "summary" in payload:
        facts.append({"title": "summary", "value": payload["summary"]})
    return {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": {
                "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "type": "AdaptiveCard",
                "version": "1.4",
                "body": [
                    {"type": "TextBlock", "size": "Medium", "weight": "Bolder",
                     "text": f"Gemini Agent Team: {status}"},
                    {"type": "FactSet", "facts": facts},
                ],
                "msteams": {"width": "Full"},
                "style": "default",
                "fallbackText": f"Gemini Agent Team: {status}",
            },
        }]
    }

if template == "slack":
    output = to_slack(data)
elif template == "discord":
    output = to_discord(data)
elif template == "teams":
    output = to_teams(data)
elif template == "teams_adaptive":
    output = to_teams_adaptive(data)
else:
    output = data

print(json.dumps(output, ensure_ascii=False))
PY
)

    curl -sS -m "${WEBHOOK_TIMEOUT:-5}" -H "Content-Type: application/json" \
        -X POST -d "$payload" "$url" >/dev/null 2>&1 || \
        log_info "⚠️  Webhook 通知に失敗しました"
}

append_error_report() {
    local phase="$1"
    local note="$2"
    local report="$RUN_DIR/ERROR_REPORT.md"
    {
        echo "## ${phase}"
        echo ""
        echo "- time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- note: ${note}"
        echo ""
    } >> "$report"
}

update_status() {
    local phase="$1"
    local status="$2"
    local note="$3"
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    python3 - <<'PY' "$STATUS_FILE" "$phase" "$status" "$note" "$RUN_ID" "$now"
import json, sys
path, phase, status, note, run_id, now = sys.argv[1:7]
data = {
    "phase": phase,
    "status": status,
    "note": note,
    "run_id": run_id,
    "updated_at": now,
}
try:
    with open(path, "r", encoding="utf-8") as f:
        prev = json.load(f)
    if isinstance(prev, dict):
        prev.update(data)
        data = prev
except Exception:
    pass
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False)
PY
}

check_maintenance_mode() {
    if [[ "${MAINTENANCE_MODE:-false}" == "true" ]]; then
        log_info "🛠️  メンテナンスモードのため実行を停止します"
        update_status "maintenance" "SKIPPED" "maintenance mode"
        return 0
    fi
    return 1
}

detect_secrets() {
    local file="$1"
    if [[ ! -f "$file" ]] || [[ ! -s "$file" ]]; then
        return 1
    fi
    python3 - <<'PY' "$file" "${TASK_SECRET_REGEX:-}" "${TASK_SECRET_ALLOW:-false}"
import re, sys
path, pattern, allow = sys.argv[1:4]
allow = str(allow).lower() == "true"
if not pattern:
    raise SystemExit(1)
try:
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        data = f.read()
    if re.search(pattern, data):
        if allow:
            print("FOUND_ALLOW")
            raise SystemExit(0)
        print("FOUND")
        raise SystemExit(0)
except Exception:
    pass
raise SystemExit(1)
PY
}

secure_paths() {
    if [[ "${SECURE_FILES:-true}" != "true" ]]; then
        return 0
    fi

    chmod 700 "$LOGS_DIR" "$HISTORY_DIR" 2>/dev/null || true
    chmod 600 "$LOGS_DIR"/*.log 2>/dev/null || true
    chmod 600 "$SWARM_LOCK_FILE" 2>/dev/null || true
    chmod 600 "$STATUS_FILE" 2>/dev/null || true
    if [[ -n "${RUN_DIR:-}" ]]; then
        chmod 700 "$RUN_DIR" 2>/dev/null || true
        chmod 600 "$RUN_DIR"/* 2>/dev/null || true
    fi
}

prune_runs() {
    local keep="${KEEP_RUNS:-20}"
    if [[ -z "$keep" ]] || [[ "$keep" -lt 1 ]]; then
        return 0
    fi

    if [[ ! -d "$HISTORY_DIR" ]]; then
        return 0
    fi

    local runs
    runs=$(ls -dt "$HISTORY_DIR"/run-* 2>/dev/null || true)
    if [[ -z "$runs" ]]; then
        return 0
    fi

    local count=0
    for run in $runs; do
        count=$((count + 1))
        if [[ $count -gt $keep ]]; then
            rm -rf "$run"
        fi
    done
}

# パイプラインをリトライ付きで実行
run_pipeline_with_retries() {
    local attempts="${PIPELINE_RETRY_COUNT:-1}"
    local delay="${PIPELINE_RETRY_DELAY:-3}"
    local attempt=1

    if [[ -z "$attempts" || "$attempts" -lt 1 ]]; then
        attempts=1
    fi

    while true; do
        PIPELINE_ATTEMPT="$attempt"
        PIPELINE_TOTAL="$attempts"
        run_pipeline
        local status=$?
        if [[ $status -eq 0 ]]; then
            return 0
        fi

        if [[ $attempt -ge $attempts ]]; then
            return $status
        fi

        log_info "♻️  パイプライン再試行 (${attempt}/${attempts}) を ${delay}s 後に実行します"
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

# 二重起動防止ロックを取得してパイプラインを実行
run_pipeline_locked() {
    if ! command -v flock &>/dev/null; then
        log_info "⚠️  flock が見つからないためロックなしで実行します"
        if check_maintenance_mode; then
            return 0
        fi
        run_pipeline_with_retries
        return $?
    fi

    mkdir -p "$(dirname "$SWARM_LOCK_FILE")"

    local lock_fd
    exec {lock_fd}>"$SWARM_LOCK_FILE"
    if ! flock -n "$lock_fd"; then
        log_info "⏭️  既にパイプラインが実行中のためスキップします"
        eval "exec ${lock_fd}>&-"
        return 0
    fi

    if check_maintenance_mode; then
        eval "exec ${lock_fd}>&-"
        return 0
    fi

    run_pipeline_with_retries
    local status=$?
    eval "exec ${lock_fd}>&-"
    return $status
}

# ============================================================
# エージェント実行
# ============================================================

# 単一エージェントの実行
# Usage: run_agent <agent_name> <role_file> <output_file> <input_file1> [input_file2] ...
run_agent() {
    local agent_name="$1"
    local role_file="$2"
    local output_file="$3"
    shift 3
    local input_files=("$@")

    local log_file="$LOGS_DIR/${agent_name}.log"
    local icon=""

    case "$agent_name" in
        analyst)            icon="🧭" ;;
        architect)          icon="📐" ;;
        architect_discuss)  icon="📐" ;;
        engineer)           icon="🔨" ;;
        engineer_discuss)   icon="🔨" ;;
        reviewer)           icon="🔍" ;;
        reviewer_discuss)   icon="🔍" ;;
        explorer)           icon="🔎" ;;
        *)                  icon="🤖" ;;
    esac

    log_agent "$agent_name" "起動中..." "$icon"

    # ログファイルをリセット（ヘッダー付き）
    {
        echo ""
        echo "╔══════════════════════════════════════════════╗"
        echo "║  ${agent_name^^} - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "╚══════════════════════════════════════════════╝"
        echo ""
    } > "$log_file"

    # タイムアウト付きでエージェント実行
    local start_time
    start_time=$(date +%s)

    if timeout "$AGENT_TIMEOUT" python3 "$SCRIPTS_DIR/gemini_runner.py" \
        --role "$role_file" \
        --input "${input_files[@]}" \
        --output "$output_file" \
        --log "$log_file" \
        --model "$GEMINI_MODEL"; then

        local elapsed=$(( $(date +%s) - start_time ))
        log_agent "$agent_name" "完了 (${elapsed}秒)" "$icon"
        echo "" >> "$log_file"
        echo "--- 完了 (${elapsed}秒) ---" >> "$log_file"
        return 0
    else
        local exit_code=$?
        local elapsed=$(( $(date +%s) - start_time ))

        if [[ $exit_code -eq 124 ]]; then
            log_error "${agent_name}: タイムアウト (${AGENT_TIMEOUT}秒)"
            echo "--- タイムアウト ---" >> "$log_file"
        else
            log_error "${agent_name}: 失敗 (exit code: ${exit_code}, ${elapsed}秒)"
            echo "--- 失敗 (exit code: ${exit_code}) ---" >> "$log_file"
        fi
        return 1
    fi
}

# ============================================================
# パイプライン実行
# ============================================================

run_pipeline() {
    local task_file="$SHARED_DIR/TASK.md"
    if [[ -z "${TASK_SOURCE:-}" ]]; then
        TASK_SOURCE="manual"
    fi

    # TASK.md の存在確認
    if [[ ! -f "$task_file" ]] || [[ ! -s "$task_file" ]]; then
        log_error "TASK.md が空か存在しません。"
        log_info "📝 shared/TASK.md にタスクを記述してください。"
        return 1
    fi

    local pipeline_start
    pipeline_start=$(date +%s)
    RUN_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p "$HISTORY_DIR"
    init_run_context
    secure_paths
    update_status "pipeline" "STARTED" "run started"

    # シークレット検知
    local secret_flag
    secret_flag=$(detect_secrets "$task_file" 2>/dev/null || true)
    if [[ "$secret_flag" == "FOUND" ]]; then
        log_error "TASK.md に機密情報が含まれている可能性があります。処理を停止します。"
        append_error_report "SECURITY" "Secret pattern detected in TASK.md"
        update_status "security" "BLOCKED" "secret detected"
        if should_finalize_task; then
            finalize_task_status "failed"
        fi
        return 1
    elif [[ "$secret_flag" == "FOUND_ALLOW" ]]; then
        log_info "⚠️  TASK.md に機密情報が含まれる可能性があります（許可済み）"
        update_status "security" "WARN" "secret detected but allowed"
    fi

    echo ""
    log_divider
    log_info "🚀 ${BOLD}パイプライン開始${NC}"
    log_info "タスク: $(head -1 "$task_file")"
    log_divider
    echo ""

    # 前回の出力をクリア
    > "$SHARED_DIR/REQUIREMENTS.md"
    > "$SHARED_DIR/PLAN.md"
    > "$SHARED_DIR/CODE_DRAFT.md"
    > "$SHARED_DIR/REVIEW.md"
    > "$DISCUSSION_FILE"

    # 入力タスクを履歴に保存
    save_artifact "TASK" "$SHARED_DIR/TASK.md"

    # ──────────────────────────────────────
    # Phase 0: Analyst（要件整理）
    # ──────────────────────────────────────
    if [[ "${ENABLE_ANALYST:-true}" == "true" ]]; then
        log_info "🧭 ${BOLD}Phase 0: 要件整理（Analyst）${NC}"
        update_status "analyst" "RUNNING" "running"
        if ! run_agent "analyst" \
            "$AGENTS_DIR/analyst.md" \
            "$SHARED_DIR/REQUIREMENTS.md" \
            "$task_file"; then
            log_error "パイプライン失敗: Analyst フェーズ"
            save_artifact "REQUIREMENTS" "$SHARED_DIR/REQUIREMENTS.md"
            local elapsed=$(( $(date +%s) - pipeline_start ))
            write_run_summary "FAILED_ANALYST" "$elapsed"
            append_error_report "ANALYST" "Agent execution failed"
            update_status "analyst" "FAILED" "agent failed"
            notify_webhook "FAILED_ANALYST" "$elapsed" ""
            prune_runs
            secure_paths
            if should_finalize_task; then
                finalize_task_status "failed"
            fi
            return 1
        fi
        update_status "analyst" "SUCCESS" "completed"
        save_artifact "REQUIREMENTS" "$SHARED_DIR/REQUIREMENTS.md"
        echo ""
    fi

    # ──────────────────────────────────────
    # Phase 0.5: Discussion（会話ベース設計）
    # ──────────────────────────────────────
    if [[ "${ENABLE_DISCUSSION:-false}" == "true" ]]; then
        log_info "💬 ${BOLD}Phase 0.5: 設計ディスカッション${NC}"
        if [[ ! -f "$AGENTS_DIR/architect_discuss.md" ]] || \
           [[ ! -f "$AGENTS_DIR/engineer_discuss.md" ]] || \
           [[ ! -f "$AGENTS_DIR/reviewer_discuss.md" ]]; then
            log_error "DISCUSSION エージェント定義が見つかりません"
            append_error_report "DISCUSSION" "Missing discussion agent definitions"
            update_status "discussion" "FAILED" "missing agent definitions"
            if should_finalize_task; then
                finalize_task_status "failed"
            fi
            return 1
        fi
        echo "# Design Discussion" > "$DISCUSSION_FILE"
        echo "" >> "$DISCUSSION_FILE"
        if [[ -s "$SHARED_DIR/REQUIREMENTS.md" ]]; then
            echo "## REQUIREMENTS" >> "$DISCUSSION_FILE"
            echo "" >> "$DISCUSSION_FILE"
            cat "$SHARED_DIR/REQUIREMENTS.md" >> "$DISCUSSION_FILE"
            echo "" >> "$DISCUSSION_FILE"
        fi

        local round=1
        while [[ $round -le ${DISCUSSION_ROUNDS:-1} ]]; do
            log_info "💬 Discussion Round ${round}/${DISCUSSION_ROUNDS}"
            run_agent_append "architect_discuss" \
                "$AGENTS_DIR/architect_discuss.md" \
                "$DISCUSSION_FILE" \
                "$task_file" "$SHARED_DIR/REQUIREMENTS.md" "$DISCUSSION_FILE" || true
            run_agent_append "engineer_discuss" \
                "$AGENTS_DIR/engineer_discuss.md" \
                "$DISCUSSION_FILE" \
                "$task_file" "$SHARED_DIR/REQUIREMENTS.md" "$DISCUSSION_FILE" || true
            run_agent_append "reviewer_discuss" \
                "$AGENTS_DIR/reviewer_discuss.md" \
                "$DISCUSSION_FILE" \
                "$task_file" "$SHARED_DIR/REQUIREMENTS.md" "$DISCUSSION_FILE" || true
            round=$((round + 1))
        done
        save_artifact "DISCUSSION" "$DISCUSSION_FILE"
        echo ""
    fi

    # ──────────────────────────────────────
    # Phase 1: Architect（設計）
    # ──────────────────────────────────────
    log_info "📐 ${BOLD}Phase 1: 設計（Architect）${NC}"
    update_status "architect" "RUNNING" "running"
    local architect_inputs=("$task_file")
    if [[ -s "$SHARED_DIR/REQUIREMENTS.md" ]]; then
        architect_inputs+=("$SHARED_DIR/REQUIREMENTS.md")
    fi
    if [[ -s "$DISCUSSION_FILE" ]]; then
        architect_inputs+=("$DISCUSSION_FILE")
    fi
    if ! run_agent "architect" \
        "$AGENTS_DIR/architect.md" \
        "$SHARED_DIR/PLAN.md" \
        "${architect_inputs[@]}"; then
        log_error "パイプライン失敗: Architect フェーズ"
        save_artifact "PLAN" "$SHARED_DIR/PLAN.md"
        local elapsed=$(( $(date +%s) - pipeline_start ))
        write_run_summary "FAILED_ARCHITECT" "$elapsed"
        append_error_report "ARCHITECT" "Agent execution failed"
        update_status "architect" "FAILED" "agent failed"
        notify_webhook "FAILED_ARCHITECT" "$elapsed" ""
        prune_runs
        secure_paths
        if should_finalize_task; then
            finalize_task_status "failed"
        fi
        return 1
    fi
    update_status "architect" "SUCCESS" "completed"
    save_artifact "PLAN" "$SHARED_DIR/PLAN.md"
    echo ""

    # ──────────────────────────────────────
    # Phase 2 & 3: Engineer + Reviewer（実装＆レビューループ）
    # ──────────────────────────────────────
    local iteration=0
    local approved=false

    while [[ $iteration -lt $MAX_REVIEW_ITERATIONS ]]; do
        iteration=$((iteration + 1))

        # --- Engineer ---
        log_info "🔨 ${BOLD}Phase 2: 実装（Engineer）[イテレーション ${iteration}/${MAX_REVIEW_ITERATIONS}]${NC}"
        update_status "engineer" "RUNNING" "running"

    # Engineer への入力を構築（コンテキスト蓄積）
    local engineer_inputs=("$task_file" "$SHARED_DIR/PLAN.md")
    if [[ -s "$SHARED_DIR/REQUIREMENTS.md" ]]; then
        engineer_inputs+=("$SHARED_DIR/REQUIREMENTS.md")
    fi
    if [[ -s "$DISCUSSION_FILE" ]]; then
        engineer_inputs+=("$DISCUSSION_FILE")
    fi

        # 前回のレビュー結果があれば追加
        if [[ -f "$SHARED_DIR/REVIEW.md" ]] && [[ -s "$SHARED_DIR/REVIEW.md" ]]; then
            engineer_inputs+=("$SHARED_DIR/REVIEW.md")
        fi

        if ! run_agent "engineer" \
            "$AGENTS_DIR/engineer.md" \
            "$SHARED_DIR/CODE_DRAFT.md" \
            "${engineer_inputs[@]}"; then
            log_error "パイプライン失敗: Engineer フェーズ"
            save_artifact "CODE_DRAFT" "$SHARED_DIR/CODE_DRAFT.md"
            save_artifact "REVIEW" "$SHARED_DIR/REVIEW.md"
            local elapsed=$(( $(date +%s) - pipeline_start ))
            write_run_summary "FAILED_ENGINEER" "$elapsed"
            append_error_report "ENGINEER" "Agent execution failed"
            update_status "engineer" "FAILED" "agent failed"
            notify_webhook "FAILED_ENGINEER" "$elapsed" ""
            prune_runs
            secure_paths
            if should_finalize_task; then
                finalize_task_status "failed"
            fi
            return 1
        fi
        update_status "engineer" "SUCCESS" "completed"
        save_artifact "CODE_DRAFT" "$SHARED_DIR/CODE_DRAFT.md"
        echo ""

        # --- Reviewer ---
        log_info "🔍 ${BOLD}Phase 3: レビュー（Reviewer）[イテレーション ${iteration}/${MAX_REVIEW_ITERATIONS}]${NC}"
        update_status "reviewer" "RUNNING" "running"

        local reviewer_inputs=("$task_file" "$SHARED_DIR/PLAN.md" "$SHARED_DIR/CODE_DRAFT.md")
        if [[ -s "$SHARED_DIR/REQUIREMENTS.md" ]]; then
            reviewer_inputs+=("$SHARED_DIR/REQUIREMENTS.md")
        fi
        if [[ -s "$DISCUSSION_FILE" ]]; then
            reviewer_inputs+=("$DISCUSSION_FILE")
        fi
        if ! run_agent "reviewer" \
            "$AGENTS_DIR/reviewer.md" \
            "$SHARED_DIR/REVIEW.md" \
            "${reviewer_inputs[@]}"; then
            log_error "パイプライン失敗: Reviewer フェーズ"
            save_artifact "REVIEW" "$SHARED_DIR/REVIEW.md"
            local elapsed=$(( $(date +%s) - pipeline_start ))
            write_run_summary "FAILED_REVIEWER" "$elapsed"
            append_error_report "REVIEWER" "Agent execution failed"
            update_status "reviewer" "FAILED" "agent failed"
            notify_webhook "FAILED_REVIEWER" "$elapsed" ""
            prune_runs
            secure_paths
            if should_finalize_task; then
                finalize_task_status "failed"
            fi
            return 1
        fi
        update_status "reviewer" "SUCCESS" "completed"
        save_artifact "REVIEW" "$SHARED_DIR/REVIEW.md"
        echo ""

        # レビュー結果の判定
        if grep -qi "LGTM" "$SHARED_DIR/REVIEW.md" 2>/dev/null; then
            if ! grep -qi "NEEDS_REVISION" "$SHARED_DIR/REVIEW.md" 2>/dev/null; then
                log_success "レビュー承認！ (LGTM)"
                approved=true
                break
            fi
        fi

        if [[ $iteration -lt $MAX_REVIEW_ITERATIONS ]]; then
            log_info "⚠️  レビューで問題が検出されました。Engineer を再実行します..."
        else
            log_info "⚠️  最大イテレーション数に達しました。レビュー課題が残っている可能性があります。"
        fi
    done

    # ──────────────────────────────────────
    # 結果サマリー
    # ──────────────────────────────────────
    local pipeline_elapsed=$(( $(date +%s) - pipeline_start ))
    echo ""
    log_divider

    if $approved; then
        log_success "${BOLD}パイプライン完了！ (${pipeline_elapsed}秒)${NC}"
        write_run_summary "SUCCESS" "$pipeline_elapsed"
        update_status "pipeline" "SUCCESS" "completed"
        local summary=""
        summary=$(python3 - <<'PY' "$SHARED_DIR/REQUIREMENTS.md" "$SHARED_DIR/PLAN.md" "$SHARED_DIR/REVIEW.md"
import sys
req, plan, review = sys.argv[1], sys.argv[2], sys.argv[3]
def first_heading_or_line(p):
    try:
        with open(p, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#"):
                    return line.lstrip("#").strip()
            f.seek(0)
            for line in f:
                line = line.strip()
                if line:
                    return line
    except Exception:
        pass
    return ""
req_line = first_heading_or_line(req)
plan_line = first_heading_or_line(plan)
review_line = first_heading_or_line(review)
review_status = ""
try:
    with open(review, "r", encoding="utf-8", errors="ignore") as f:
        text = f.read()
    if "NEEDS_REVISION" in text:
        review_status = "NEEDS_REVISION"
    elif "LGTM" in text:
        review_status = "LGTM"
except Exception:
    pass
parts = []
if req_line:
    parts.append(f"req: {req_line}")
if plan_line:
    parts.append(f"plan: {plan_line}")
if review_line:
    parts.append(f"review: {review_line}")
if review_status:
    parts.append(f"review_status: {review_status}")
print(" | ".join(parts))
PY
)
        notify_webhook "SUCCESS" "$pipeline_elapsed" "$summary"
        if should_finalize_task; then
            finalize_task_status "done"
        fi
    else
        log_info "🏁 ${BOLD}パイプライン終了 (${pipeline_elapsed}秒) - レビュー課題が残っている可能性があります${NC}"
        write_run_summary "COMPLETED_WITH_ISSUES" "$pipeline_elapsed"
        append_error_report "REVIEW" "Completed with review issues"
        update_status "pipeline" "COMPLETED_WITH_ISSUES" "review issues"
        notify_webhook "COMPLETED_WITH_ISSUES" "$pipeline_elapsed" ""
        if should_finalize_task; then
            finalize_task_status "failed"
        fi
    fi

    # ログのスナップショットを保存
    redact_copy "$LOGS_DIR/analyst.log" "$RUN_DIR/analyst.log" 2>/dev/null || true
    redact_copy "$LOGS_DIR/architect.log" "$RUN_DIR/architect.log" 2>/dev/null || true
    redact_copy "$LOGS_DIR/engineer.log" "$RUN_DIR/engineer.log" 2>/dev/null || true
    redact_copy "$LOGS_DIR/reviewer.log" "$RUN_DIR/reviewer.log" 2>/dev/null || true

    prune_runs
    secure_paths

    log_info "📄 成果物:"
    log_info "   設計書:     shared/PLAN.md"
    log_info "   コード:     shared/CODE_DRAFT.md"
    log_info "   レビュー:   shared/REVIEW.md"
    log_info "   履歴保存:   $RUN_DIR"
    log_info "   エラー報告: $RUN_DIR/ERROR_REPORT.md"
    log_divider
    echo ""
}

# ============================================================
# ウォッチモード
# ============================================================

watch_mode() {
    log_divider
    log_info "👀 ${BOLD}ウォッチモード起動${NC}"
    log_info "📝 shared/TASK.md を編集・保存するとパイプラインが自動実行されます"
    log_info "   例: nano shared/TASK.md"
    log_info "   終了: Ctrl+C"
    log_divider
    echo ""

    # ディレクトリとファイルの初期化
    mkdir -p "$SHARED_DIR" "$LOGS_DIR"
    touch "$SHARED_DIR/TASK.md"

    # 初期ハッシュを取得
    local last_hash
    last_hash=$(get_file_hash "$SHARED_DIR/TASK.md")

    # inotifywait の利用可否をチェック
    local use_inotify=false
    if command -v inotifywait &>/dev/null; then
        use_inotify=true
        log_info "✨ inotifywait が利用可能です（高効率モード）"
    else
        log_info "💡 ヒント: inotify-tools をインストールすると効率的にファイル監視できます"
        log_info "   sudo apt install inotify-tools"
    fi
    echo ""

    # グレースフルシャットダウン
    trap 'echo -e "\n${CYAN}[$(date "+%H:%M:%S")]${NC} 👋 Agent Team を終了します。"; exit 0' INT TERM

    while true; do
        if check_maintenance_mode; then
            sleep "${WATCH_POLL_INTERVAL:-2}"
            continue
        fi

        # タスクキューから自動取得
        if pick_next_task; then
            local current_hash
            current_hash=$(get_file_hash "$SHARED_DIR/TASK.md")
            if [[ -n "$current_hash" ]]; then
                last_hash="$current_hash"
                sleep "${TASK_DEBOUNCE_SECONDS:-0.5}"
                if ! wait_for_stable_file "$SHARED_DIR/TASK.md"; then
                    log_info "ℹ️  TASK.md が空のためスキップします"
                else
                    run_pipeline_locked || true
                fi
                echo ""
                log_info "👀 次の変更を待機中..."
                echo ""
            fi
            continue
        fi

        # ファイル変更の待機
        if $use_inotify; then
            # inotifywait: ファイル変更イベントをブロッキング待機
            if ! inotifywait -q -e modify,close_write,move "$SHARED_DIR/TASK.md" 2>/dev/null; then
                log_info "⚠️  inotifywait が失敗しました。ポーリングに切り替えます"
                use_inotify=false
                sleep "${WATCH_POLL_INTERVAL:-2}"
                continue
            fi
            # 書き込み完了を少し待つ
            sleep "${TASK_DEBOUNCE_SECONDS:-0.5}"
        else
            # ポーリング
            sleep "${WATCH_POLL_INTERVAL:-2}"
        fi

        # ハッシュで実際に内容が変わったか確認（重複実行防止）
        local current_hash
        current_hash=$(get_file_hash "$SHARED_DIR/TASK.md")

        if [[ -n "$current_hash" && "$current_hash" != "$last_hash" ]]; then
            last_hash="$current_hash"
            log_info "⚡ TASK.md の変更を検出しました！"

            # 追記・保存中の揺れを吸収
            sleep "${TASK_DEBOUNCE_SECONDS:-0.5}"
            if ! wait_for_stable_file "$SHARED_DIR/TASK.md"; then
                log_info "ℹ️  TASK.md が空のためスキップします"
                continue
            fi

            run_pipeline_locked || true
            echo ""
            log_info "👀 次の変更を待機中..."
            echo ""
        fi
    done
}

# ============================================================
# メイン
# ============================================================

case "${1:-watch}" in
    run)
        run_pipeline_locked
        ;;
    watch)
        watch_mode
        ;;
    *)
        echo "Usage: $0 {run|watch}"
        echo ""
        echo "  run    - TASK.md を一度だけ処理する"
        echo "  watch  - TASK.md の変更を監視して自動処理する（デフォルト）"
        exit 1
        ;;
esac
