#!/bin/bash
# ============================================================
# Gemini Agent Team - 起動スクリプト
# ============================================================
# tmux セッションを作成し、6分割ペインで各エージェントの
# リアルタイム出力を表示しつつ、オーケストレータを起動する。
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

SESSION="$SWARM_SESSION"

# ============================================================
# 前提条件チェック
# ============================================================

check_prerequisites() {
    local errors=0

    # tmux
    if ! command -v tmux &>/dev/null; then
        echo "❌ tmux がインストールされていません"
        [[ "$(uname)" == "Darwin" ]] && echo "   brew install tmux" || echo "   sudo apt install tmux"
        errors=$((errors + 1))
    fi

    # Gemini CLI
    if ! command -v gemini &>/dev/null; then
        echo "❌ gemini CLI がインストールされていません"
        echo "   npm install -g @google/gemini-cli"
        errors=$((errors + 1))
    else
        echo "   Gemini CLI: $(gemini --version 2>/dev/null || echo 'installed')"
    fi

    # 必須ファイル
    for file in "$AGENTS_DIR/analyst.md" "$AGENTS_DIR/architect.md" \
                "$AGENTS_DIR/engineer.md" "$AGENTS_DIR/reviewer.md" \
                "$SCRIPTS_DIR/gemini_runner.sh" "$SCRIPTS_DIR/orchestrator.sh"; do
        if [[ ! -f "$file" ]]; then
            echo "❌ 必須ファイルが見つかりません: $file"
            errors=$((errors + 1))
        fi
    done

    if [[ $errors -gt 0 ]]; then
        echo ""
        echo "🛑 ${errors} 個のエラーがあります。上記を解決してから再実行してください。"
        exit 1
    fi

    # 警告（動作に支障なし）
    if ! command -v timeout &>/dev/null && ! command -v gtimeout &>/dev/null; then
        echo "⚠️  timeout が見つかりません（タイムアウト制御が無効）"
        [[ "$(uname)" == "Darwin" ]] && echo "   brew install coreutils"
    fi
}

# ============================================================
# メイン
# ============================================================

main() {
    echo "╔══════════════════════════════════════════════╗"
    echo "║         Gemini Agent Team Controller         ║"
    echo "║   Agent Team powered by Gemini + tmux        ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    echo "📁 プロジェクト: $PROJECT_NAME"
    echo ""

    check_prerequisites
    echo "✅ 前提条件チェック完了"

    # 既存セッションのクリーンアップ
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "⚠️  既存セッション ($SESSION) を終了します..."
        tmux kill-session -t "$SESSION"
    fi

    # ディレクトリ作成
    mkdir -p "$PROJECT_DIR" "$LOGS_DIR"
    touch "$PROJECT_DIR/REQUEST.md"

    # ログ初期化
    for agent in analyst architect engineer reviewer; do
        echo "🕐 パイプライン待機中..." > "$LOGS_DIR/${agent}.log"
    done
    echo "[$(date '+%H:%M:%S')] 起動完了 (project: $PROJECT_NAME)" > "$STATUS_FILE"

    echo "🔧 tmux セッションを構築中..."

    # ── tmux セッション構築（2行 x 3列） ──

    tmux new-session -d -s "$SESSION" -n "AgentTeam" -x 220 -y 55

    tmux split-window -h -t "$SESSION:0"
    tmux split-window -h -t "$SESSION:0.1"
    tmux split-window -v -t "$SESSION:0.0"
    tmux split-window -v -t "$SESSION:0.1"
    tmux split-window -v -t "$SESSION:0.2"

    # ペインタイトル
    tmux select-pane -t "$SESSION:0.0" -T "🎮 ORCHESTRATOR"
    tmux select-pane -t "$SESSION:0.1" -T "🧭 ANALYST"
    tmux select-pane -t "$SESSION:0.2" -T "📐 ARCHITECT"
    tmux select-pane -t "$SESSION:0.3" -T "🔨 ENGINEER"
    tmux select-pane -t "$SESSION:0.4" -T "🔍 REVIEWER"
    tmux select-pane -t "$SESSION:0.5" -T "📊 STATUS"

    tmux set-option -t "$SESSION" pane-border-status top
    tmux set-option -t "$SESSION" pane-border-format " #{pane_title} "
    tmux set-option -t "$SESSION" pane-border-style "fg=colour240"
    tmux set-option -t "$SESSION" pane-active-border-style "fg=colour39"

    # ── 各ペインでプロセス起動 ──

    # 環境変数を tmux セッションに引き継ぎ
    tmux set-environment -t "$SESSION" GEMINI_API_KEY "${GEMINI_API_KEY:-}"
    tmux set-environment -t "$SESSION" GEMINI_MODEL "${GEMINI_MODEL:-gemini-2.5-flash}"
    tmux set-environment -t "$SESSION" PROJECT_NAME "${PROJECT_NAME:-default}"

    tmux send-keys -t "$SESSION:0.1" "tail -f '$LOGS_DIR/analyst.log'" C-m
    tmux send-keys -t "$SESSION:0.2" "tail -f '$LOGS_DIR/architect.log'" C-m
    tmux send-keys -t "$SESSION:0.3" "tail -f '$LOGS_DIR/engineer.log'" C-m
    tmux send-keys -t "$SESSION:0.4" "tail -f '$LOGS_DIR/reviewer.log'" C-m
    tmux send-keys -t "$SESSION:0.5" "tail -f '$STATUS_FILE'" C-m

    # Orchestrator（メイン制御）
    tmux send-keys -t "$SESSION:0.0" "cd '$SWARM_DIR' && bash scripts/orchestrator.sh watch" C-m
    tmux select-pane -t "$SESSION:0.0"

    # ── 完了 ──
    echo "✅ Agent Team 準備完了！"
    echo ""
    echo "💡 使い方:"
    echo "   1. 別ターミナルで project/$PROJECT_NAME/REQUEST.md を編集してリクエストを投入"
    echo "      例: echo 'FizzBuzzを実装して' > project/$PROJECT_NAME/REQUEST.md"
    echo "   2. Analyst が仕様検討・タスク分解 → 各エージェントが自動的に連鎖実行されます"
    echo ""
    echo "   デタッチ: Ctrl+B → D"
    echo "   再アタッチ: tmux attach -t $SESSION"
    echo ""

    tmux attach -t "$SESSION"
}

main "$@"
