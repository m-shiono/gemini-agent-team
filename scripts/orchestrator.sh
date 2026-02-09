#!/bin/bash
# ============================================================
# Gemini Agent Team Orchestrator
# ============================================================
# エージェントパイプラインを管理する中央制御スクリプト。
#
# パイプライン:
#   REQUEST.md → Analyst → TASK.md + REQUIREMENTS.md
#              → (Discussion) → Architect → Engineer ⇄ Reviewer
#
# モード:
#   watch  - REQUEST.md の変更を監視して自動実行（デフォルト）
#   run    - REQUEST.md を一度だけ処理する
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWARM_DIR="$(dirname "$SCRIPT_DIR")"

source "$SWARM_DIR/config.sh"

# ============================================================
# ユーティリティ
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"; }
log_success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅ $1${NC}"; }
log_error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ❌ $1${NC}"; }
log_divider() { echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

log_agent() {
    local agent="$1" msg="$2" icon="$3"
    echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} ${icon} ${BOLD}[${agent}]${NC} ${msg}"
}

# ステータスログに追記（tmux の STATUS ペインで tail -f される）
update_status() {
    echo "[$(date '+%H:%M:%S')] $1: $2" >> "$STATUS_FILE"
}

# ファイルハッシュ取得（macOS / Linux 両対応）
get_file_hash() {
    local file="$1"
    if [[ -f "$file" && -s "$file" ]]; then
        if command -v md5sum &>/dev/null; then
            md5sum "$file" 2>/dev/null | cut -d' ' -f1
        elif command -v md5 &>/dev/null; then
            md5 -q "$file" 2>/dev/null
        else
            shasum "$file" 2>/dev/null | cut -d' ' -f1
        fi
    else
        echo ""
    fi
}

# ファイルが安定するまで待機
wait_for_stable_file() {
    local file="$1" checks=2 interval=0.5
    [[ ! -f "$file" || ! -s "$file" ]] && return 1

    local last_hash="" stable=0
    while true; do
        local h; h=$(get_file_hash "$file")
        if [[ -n "$h" && "$h" == "$last_hash" ]]; then
            stable=$((stable + 1))
        else
            stable=0; last_hash="$h"
        fi
        [[ $stable -ge $checks ]] && return 0
        sleep "$interval"
    done
}

# ============================================================
# エージェント実行
# ============================================================

run_agent() {
    local agent_name="$1" role_file="$2" output_file="$3"
    shift 3
    local input_files=("$@")
    local log_file="$LOGS_DIR/${agent_name}.log"
    local icon="🤖"

    case "$agent_name" in
        analyst|analyst_*)     icon="🧭" ;;
        architect|architect_*) icon="📐" ;;
        engineer|engineer_*)   icon="🔨" ;;
        reviewer|reviewer_*)   icon="🔍" ;;
    esac

    log_agent "$agent_name" "起動中..." "$icon"
    update_status "$agent_name" "RUNNING"

    # ログヘッダー
    printf '\n╔══════════════════════════════════════════════╗\n║  %s - %s\n╚══════════════════════════════════════════════╝\n\n' \
        "${agent_name^^}" "$(date '+%Y-%m-%d %H:%M:%S')" > "$log_file"

    # timeout コマンド検出（macOS: gtimeout）
    local timeout_cmd=""
    command -v timeout  &>/dev/null && timeout_cmd="timeout"
    command -v gtimeout &>/dev/null && timeout_cmd="gtimeout"

    local start_time; start_time=$(date +%s)
    local runner_cmd=(bash "$SCRIPTS_DIR/gemini_runner.sh"
        --role "$role_file"
        --input "${input_files[@]}"
        --output "$output_file"
        --log "$log_file"
        --model "$GEMINI_MODEL"
    )

    local ok=false
    if [[ -n "$timeout_cmd" ]]; then
        "$timeout_cmd" "$AGENT_TIMEOUT" "${runner_cmd[@]}" && ok=true
    else
        "${runner_cmd[@]}" && ok=true
    fi

    local elapsed=$(( $(date +%s) - start_time ))

    if $ok; then
        log_agent "$agent_name" "完了 (${elapsed}秒)" "$icon"
        echo "--- 完了 (${elapsed}秒) ---" >> "$log_file"
        update_status "$agent_name" "SUCCESS (${elapsed}s)"
        return 0
    else
        local code=$?
        if [[ $code -eq 124 ]]; then
            log_error "${agent_name}: タイムアウト (${AGENT_TIMEOUT}秒)"
            echo "--- タイムアウト ---" >> "$log_file"
        else
            log_error "${agent_name}: 失敗 (exit: ${code}, ${elapsed}秒)"
            echo "--- 失敗 (exit: ${code}) ---" >> "$log_file"
        fi
        update_status "$agent_name" "FAILED"
        return 1
    fi
}

# Discussion 用: エージェント出力をファイルに追記
run_agent_append() {
    local agent_name="$1" role_file="$2" output_file="$3"
    shift 3
    local input_files=("$@")
    local tmp_out; tmp_out=$(mktemp)

    if run_agent "$agent_name" "$role_file" "$tmp_out" "${input_files[@]}"; then
        { echo "## ${agent_name^^}"; echo ""; cat "$tmp_out"; echo ""; } >> "$output_file"
        rm -f "$tmp_out"
        return 0
    fi
    rm -f "$tmp_out"
    return 1
}

# ============================================================
# パイプライン
# ============================================================

run_pipeline() {
    local request_file="$PROJECT_DIR/REQUEST.md"

    if [[ ! -f "$request_file" || ! -s "$request_file" ]]; then
        log_error "REQUEST.md が空か存在しません。"
        log_info "📝 project/$PROJECT_NAME/REQUEST.md にリクエストを記述してください。"
        return 1
    fi

    local pipeline_start; pipeline_start=$(date +%s)

    echo ""
    log_divider
    log_info "🚀 ${BOLD}パイプライン開始${NC} (プロジェクト: ${PROJECT_NAME})"
    log_info "リクエスト: $(head -1 "$request_file")"
    log_divider
    echo ""
    update_status "pipeline" "STARTED ($PROJECT_NAME)"

    # 前回の出力をクリア
    > "$PROJECT_DIR/TASK.md"
    > "$PROJECT_DIR/REQUIREMENTS.md"
    > "$PROJECT_DIR/PLAN.md"
    > "$PROJECT_DIR/CODE_DRAFT.md"
    > "$PROJECT_DIR/REVIEW.md"
    > "$DISCUSSION_FILE"

    # ── Phase 0: Analyst（仕様検討・タスク分解）──
    if [[ "${ENABLE_ANALYST:-true}" == "true" ]]; then
        log_info "🧭 ${BOLD}Phase 0: 仕様検討・タスク分解（Analyst）${NC}"

        # Analyst は REQUIREMENTS.md と TASK.md の両方を出力する
        # まず REQUIREMENTS.md を出力先として実行
        if ! run_agent "analyst" "$AGENTS_DIR/analyst.md" \
                "$PROJECT_DIR/REQUIREMENTS.md" "$request_file"; then
            log_error "パイプライン失敗: Analyst フェーズ"
            return 1
        fi

        # TASK.md が Analyst によって生成されていない場合はリクエストを引き継ぐ
        if [[ ! -s "$PROJECT_DIR/TASK.md" ]]; then
            log_info "⚠️  TASK.md が未生成のため、REQUEST.md の内容を引き継ぎます"
            cp "$request_file" "$PROJECT_DIR/TASK.md"
        fi
        echo ""
    else
        # Analyst スキップ時は REQUEST.md をそのまま TASK.md として使う
        cp "$request_file" "$PROJECT_DIR/TASK.md"
    fi

    # ── Phase 0.5: Discussion（設計ディスカッション）──
    if [[ "${ENABLE_DISCUSSION:-false}" == "true" ]]; then
        log_info "💬 ${BOLD}Phase 0.5: 設計ディスカッション${NC}"

        echo "# Design Discussion" > "$DISCUSSION_FILE"
        echo "" >> "$DISCUSSION_FILE"
        if [[ -s "$PROJECT_DIR/REQUIREMENTS.md" ]]; then
            { echo "## REQUIREMENTS"; echo ""; cat "$PROJECT_DIR/REQUIREMENTS.md"; echo ""; } >> "$DISCUSSION_FILE"
        fi

        local round=1
        while [[ $round -le ${DISCUSSION_ROUNDS:-1} ]]; do
            log_info "💬 Discussion Round ${round}/${DISCUSSION_ROUNDS}"
            run_agent_append "architect_discuss" "$AGENTS_DIR/architect_discuss.md" \
                "$DISCUSSION_FILE" "$request_file" "$PROJECT_DIR/TASK.md" "$PROJECT_DIR/REQUIREMENTS.md" "$DISCUSSION_FILE" || true
            run_agent_append "engineer_discuss" "$AGENTS_DIR/engineer_discuss.md" \
                "$DISCUSSION_FILE" "$request_file" "$PROJECT_DIR/TASK.md" "$PROJECT_DIR/REQUIREMENTS.md" "$DISCUSSION_FILE" || true
            run_agent_append "reviewer_discuss" "$AGENTS_DIR/reviewer_discuss.md" \
                "$DISCUSSION_FILE" "$request_file" "$PROJECT_DIR/TASK.md" "$PROJECT_DIR/REQUIREMENTS.md" "$DISCUSSION_FILE" || true
            round=$((round + 1))
        done
        echo ""
    fi

    # ── Phase 1: Architect（設計）──
    log_info "📐 ${BOLD}Phase 1: 設計（Architect）${NC}"
    local arch_in=("$PROJECT_DIR/TASK.md")
    [[ -s "$PROJECT_DIR/REQUIREMENTS.md" ]] && arch_in+=("$PROJECT_DIR/REQUIREMENTS.md")
    [[ -s "$DISCUSSION_FILE" ]]             && arch_in+=("$DISCUSSION_FILE")

    if ! run_agent "architect" "$AGENTS_DIR/architect.md" \
            "$PROJECT_DIR/PLAN.md" "${arch_in[@]}"; then
        log_error "パイプライン失敗: Architect フェーズ"
        return 1
    fi
    echo ""

    # ── Phase 2 & 3: Engineer ⇄ Reviewer（実装＆レビューループ）──
    local iteration=0 approved=false

    while [[ $iteration -lt $MAX_REVIEW_ITERATIONS ]]; do
        iteration=$((iteration + 1))

        # --- Engineer ---
        log_info "🔨 ${BOLD}Phase 2: 実装（Engineer）[${iteration}/${MAX_REVIEW_ITERATIONS}]${NC}"
        local eng_in=("$PROJECT_DIR/TASK.md" "$PROJECT_DIR/PLAN.md")
        [[ -s "$PROJECT_DIR/REQUIREMENTS.md" ]] && eng_in+=("$PROJECT_DIR/REQUIREMENTS.md")
        [[ -s "$DISCUSSION_FILE" ]]             && eng_in+=("$DISCUSSION_FILE")
        [[ -s "$PROJECT_DIR/REVIEW.md" ]]       && eng_in+=("$PROJECT_DIR/REVIEW.md")

        if ! run_agent "engineer" "$AGENTS_DIR/engineer.md" \
                "$PROJECT_DIR/CODE_DRAFT.md" "${eng_in[@]}"; then
            log_error "パイプライン失敗: Engineer フェーズ"
            return 1
        fi
        echo ""

        # --- Reviewer ---
        log_info "🔍 ${BOLD}Phase 3: レビュー（Reviewer）[${iteration}/${MAX_REVIEW_ITERATIONS}]${NC}"
        local rev_in=("$PROJECT_DIR/TASK.md" "$PROJECT_DIR/PLAN.md" "$PROJECT_DIR/CODE_DRAFT.md")
        [[ -s "$PROJECT_DIR/REQUIREMENTS.md" ]] && rev_in+=("$PROJECT_DIR/REQUIREMENTS.md")
        [[ -s "$DISCUSSION_FILE" ]]             && rev_in+=("$DISCUSSION_FILE")

        if ! run_agent "reviewer" "$AGENTS_DIR/reviewer.md" \
                "$PROJECT_DIR/REVIEW.md" "${rev_in[@]}"; then
            log_error "パイプライン失敗: Reviewer フェーズ"
            return 1
        fi
        echo ""

        # レビュー判定
        if grep -qi "LGTM" "$PROJECT_DIR/REVIEW.md" 2>/dev/null; then
            if ! grep -qi "NEEDS_REVISION" "$PROJECT_DIR/REVIEW.md" 2>/dev/null; then
                log_success "レビュー承認！ (LGTM)"
                approved=true
                break
            fi
        fi

        if [[ $iteration -lt $MAX_REVIEW_ITERATIONS ]]; then
            log_info "⚠️  レビューで問題が検出されました。Engineer を再実行します..."
        else
            log_info "⚠️  最大イテレーション数に達しました。"
        fi
    done

    # ── 結果 ──
    local elapsed=$(( $(date +%s) - pipeline_start ))
    echo ""
    log_divider

    if $approved; then
        log_success "${BOLD}パイプライン完了！ (${elapsed}秒)${NC}"
        update_status "pipeline" "SUCCESS (${elapsed}s)"
    else
        log_info "🏁 ${BOLD}パイプライン終了 (${elapsed}秒) - レビュー課題が残っています${NC}"
        update_status "pipeline" "COMPLETED_WITH_ISSUES (${elapsed}s)"
    fi

    log_info "📄 成果物: (project/$PROJECT_NAME/)"
    log_info "   リクエスト: REQUEST.md"
    log_info "   要件定義:   REQUIREMENTS.md"
    log_info "   タスク:     TASK.md"
    log_info "   設計書:     PLAN.md"
    log_info "   コード:     CODE_DRAFT.md"
    log_info "   レビュー:   REVIEW.md"
    log_divider
    echo ""
}

# ============================================================
# ウォッチモード
# ============================================================

watch_mode() {
    log_divider
    log_info "👀 ${BOLD}ウォッチモード起動${NC} (プロジェクト: ${PROJECT_NAME})"
    log_info "📝 project/$PROJECT_NAME/REQUEST.md を編集・保存するとパイプラインが自動実行されます"
    log_info "   終了: Ctrl+C"
    log_divider
    echo ""

    mkdir -p "$PROJECT_DIR" "$LOGS_DIR"
    touch "$PROJECT_DIR/REQUEST.md"

    local last_hash; last_hash=$(get_file_hash "$PROJECT_DIR/REQUEST.md")

    # inotifywait チェック
    local use_inotify=false
    if command -v inotifywait &>/dev/null; then
        use_inotify=true
        log_info "✨ inotifywait 利用可能（高効率モード）"
    elif command -v fswatch &>/dev/null; then
        log_info "✨ fswatch 利用可能（macOS 高効率モード）"
    else
        log_info "💡 ポーリングモード (${WATCH_POLL_INTERVAL}秒間隔)"
    fi
    echo ""

    trap 'echo -e "\n${CYAN}[$(date "+%H:%M:%S")]${NC} 👋 Agent Team を終了します。"; exit 0' INT TERM

    while true; do
        # ファイル変更の待機
        if $use_inotify; then
            inotifywait -q -e modify,close_write,move "$PROJECT_DIR/REQUEST.md" 2>/dev/null || {
                use_inotify=false
                sleep "${WATCH_POLL_INTERVAL:-2}"
                continue
            }
            sleep 0.5
        else
            sleep "${WATCH_POLL_INTERVAL:-2}"
        fi

        # ハッシュ比較で変更検出
        local current_hash; current_hash=$(get_file_hash "$PROJECT_DIR/REQUEST.md")
        if [[ -n "$current_hash" && "$current_hash" != "$last_hash" ]]; then
            last_hash="$current_hash"
            log_info "⚡ REQUEST.md の変更を検出しました！"

            sleep 0.5
            if ! wait_for_stable_file "$PROJECT_DIR/REQUEST.md"; then
                log_info "ℹ️  REQUEST.md が空のためスキップします"
                continue
            fi

            run_pipeline || true
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
    run)   run_pipeline ;;
    watch) watch_mode ;;
    *)
        echo "Usage: $0 {run|watch}"
        echo "  run    - REQUEST.md を一度だけ処理する"
        echo "  watch  - REQUEST.md の変更を監視して自動処理する（デフォルト）"
        exit 1
        ;;
esac
