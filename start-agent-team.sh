#!/bin/bash
# ============================================================
# Gemini Agent Team - 起動スクリプト
# ============================================================
# tmux セッションを作成し、6分割ペインで各エージェントの
# リアルタイム出力を表示しつつ、オーケストレータを起動する。
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 設定の読み込み
source "$SCRIPT_DIR/config.sh"

SESSION="$SWARM_SESSION"

# ============================================================
# 前提条件チェック
# ============================================================

check_prerequisites() {
    local errors=0

    # tmux
    if ! command -v tmux &>/dev/null; then
        echo "❌ Error: tmux がインストールされていません"
        echo "   sudo apt install tmux"
        errors=$((errors + 1))
    fi

    # Python 3
    if ! command -v python3 &>/dev/null; then
        echo "❌ Error: python3 がインストールされていません"
        errors=$((errors + 1))
    fi

    # google-genai SDK
    if ! python3 -c "from google import genai" 2>/dev/null; then
        echo "❌ Error: google-genai パッケージがインストールされていません"
        echo "   pip install google-genai"
        errors=$((errors + 1))
    fi

    # 認証モードに応じたチェック
    local auth_mode="${GEMINI_AUTH_MODE:-auto}"
    case "$auth_mode" in
        auto)
            local has_any=false
            if [[ -n "${GEMINI_API_KEY:-}" ]]; then
                has_any=true
            fi
            if [[ -n "${GEMINI_GCP_PROJECT:-}" || -n "${GEMINI_GCP_LOCATION:-}" ]]; then
                has_any=true
            fi
            if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
                has_any=true
            fi
            if ! python3 -c "
import google.auth
google.auth.default()
" 2>/dev/null; then
                : # ADC 未設定でも他の手段があればOK
            else
                has_any=true
            fi
            if [[ "$has_any" != "true" ]]; then
                echo "❌ Error: 認証情報が検出できません (GEMINI_AUTH_MODE=auto)"
                echo "   - GEMINI_API_KEY を設定する"
                echo "   - または GEMINI_GCP_PROJECT を設定して Vertex AI を使う"
                echo "   - または gcloud auth application-default login を実行する"
                errors=$((errors + 1))
            fi
            ;;
        api_key)
            if [[ -z "${GEMINI_API_KEY:-}" ]]; then
                echo "❌ Error: GEMINI_API_KEY 環境変数が設定されていません"
                echo "   export GEMINI_API_KEY='your-api-key-here'"
                echo "   (Google AI Studio: https://aistudio.google.com/apikey)"
                errors=$((errors + 1))
            fi
            ;;
        vertex_ai)
            if [[ -z "${GEMINI_GCP_PROJECT:-}" ]]; then
                echo "❌ Error: GEMINI_GCP_PROJECT 環境変数が設定されていません"
                echo "   export GEMINI_GCP_PROJECT='your-project-id'"
                errors=$((errors + 1))
            fi
            if ! command -v gcloud &>/dev/null; then
                echo "⚠️  Warning: gcloud CLI が見つかりません（Vertex AI 認証に必要な場合があります）"
            fi
            ;;
        adc)
            if ! python3 -c "
import google.auth
credentials, project = google.auth.default()
" 2>/dev/null; then
                echo "❌ Error: Application Default Credentials が設定されていません"
                echo "   gcloud auth application-default login を実行してください"
                errors=$((errors + 1))
            fi
            ;;
        *)
            echo "❌ Error: 不明な認証モード: $auth_mode"
            echo "   GEMINI_AUTH_MODE は auto / api_key / vertex_ai / adc のいずれかを設定してください"
            errors=$((errors + 1))
            ;;
    esac
    echo "   認証モード: $auth_mode"

    # 必須ファイル
    for file in "$AGENTS_DIR/analyst.md" "$AGENTS_DIR/architect.md" "$AGENTS_DIR/engineer.md" "$AGENTS_DIR/reviewer.md" "$SCRIPTS_DIR/gemini_runner.py" "$SCRIPTS_DIR/orchestrator.sh"; do
        if [[ ! -f "$file" ]]; then
            echo "❌ Error: 必須ファイルが見つかりません: $file"
            errors=$((errors + 1))
        fi
    done

    if [[ $errors -gt 0 ]]; then
        echo ""
        echo "🛑 ${errors} 個のエラーがあります。上記を解決してから再実行してください。"
        exit 1
    fi

    if [[ "${SECURE_FILES:-true}" == "true" ]]; then
        echo "🔒 セキュアモード: umask=${UMASK_VALUE:-077}"
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

    # 前提条件チェック
    check_prerequisites
    echo "✅ 前提条件チェック完了"

    # 既存セッションのクリーンアップ
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "⚠️  既存の Agent Team セッション ($SESSION) を終了します..."
        tmux kill-session -t "$SESSION"
    fi

    # ディレクトリ作成
    mkdir -p "$SHARED_DIR" "$LOGS_DIR"
    touch "$SHARED_DIR/TASK.md"

    # ログファイルの初期化
    for agent in analyst architect engineer reviewer; do
        echo "🕐 パイプライン待機中..." > "$LOGS_DIR/${agent}.log"
    done
    echo "{}" > "$STATUS_FILE"

    echo "🔧 tmux セッションを構築中..."

    # ────────────────────────────────────────
    # tmux セッション構築
    # ────────────────────────────────────────

    # 新規セッション作成（Pane 0: 左上）
    tmux new-session -d -s "$SESSION" -n "AgentTeam" -x 220 -y 55

    # 3列に分割 → Pane 0 (左), Pane 1 (中), Pane 2 (右)
    tmux split-window -h -t "$SESSION:0"
    tmux split-window -h -t "$SESSION:0.1"

    # 各列を上下に分割 → 2行 x 3列
    tmux split-window -v -t "$SESSION:0.0"   # Pane 3 (左下)
    tmux split-window -v -t "$SESSION:0.1"   # Pane 4 (中下)
    tmux split-window -v -t "$SESSION:0.2"   # Pane 5 (右下)

    # ペインにタイトルを設定
    tmux select-pane -t "$SESSION:0.0" -T "🎮 ORCHESTRATOR"
    tmux select-pane -t "$SESSION:0.1" -T "🧭 ANALYST"
    tmux select-pane -t "$SESSION:0.2" -T "📐 ARCHITECT"
    tmux select-pane -t "$SESSION:0.3" -T "🔨 ENGINEER"
    tmux select-pane -t "$SESSION:0.4" -T "🔍 REVIEWER"
    tmux select-pane -t "$SESSION:0.5" -T "📊 STATUS"

    # ペインボーダーにタイトルを表示
    tmux set-option -t "$SESSION" pane-border-status top
    tmux set-option -t "$SESSION" pane-border-format " #{pane_title} "

    # ペインのスタイル設定（視認性向上）
    tmux set-option -t "$SESSION" pane-border-style "fg=colour240"
    tmux set-option -t "$SESSION" pane-active-border-style "fg=colour39"

    # ────────────────────────────────────────
    # 各ペインでプロセス起動
    # ────────────────────────────────────────

    # tmux セッションに認証情報を設定（画面に残さない）
    tmux set-environment -g GEMINI_AUTH_MODE "${GEMINI_AUTH_MODE:-auto}"
    tmux set-environment -g GEMINI_MODEL "${GEMINI_MODEL:-gemini-2.5-flash}"
    tmux set-environment -g GEMINI_API_KEY "${GEMINI_API_KEY:-}"
    tmux set-environment -g GEMINI_GCP_PROJECT "${GEMINI_GCP_PROJECT:-}"
    tmux set-environment -g GEMINI_GCP_LOCATION "${GEMINI_GCP_LOCATION:-us-central1}"
    tmux set-environment -g GOOGLE_APPLICATION_CREDENTIALS "${GOOGLE_APPLICATION_CREDENTIALS:-}"

    # Pane 1 (中上): Analyst ログ表示
    tmux send-keys -t "$SESSION:0.1" "clear && echo '🧭 Analyst ログ (リアルタイム)' && echo '─────────────────────────────────' && tail -f '$LOGS_DIR/analyst.log'" C-m

    # Pane 2 (右上): Architect ログ表示
    tmux send-keys -t "$SESSION:0.2" "clear && echo '📐 Architect ログ (リアルタイム)' && echo '─────────────────────────────────' && tail -f '$LOGS_DIR/architect.log'" C-m

    # Pane 3 (左下): Engineer ログ表示
    tmux send-keys -t "$SESSION:0.3" "clear && echo '🔨 Engineer ログ (リアルタイム)' && echo '─────────────────────────────────' && tail -f '$LOGS_DIR/engineer.log'" C-m

    # Pane 4 (中下): Reviewer ログ表示
    tmux send-keys -t "$SESSION:0.4" "clear && echo '🔍 Reviewer ログ (リアルタイム)' && echo '─────────────────────────────────' && tail -f '$LOGS_DIR/reviewer.log'" C-m

    # Pane 5 (右下): Status 表示
    tmux send-keys -t "$SESSION:0.5" "clear && echo '📊 Status (リアルタイム)' && echo '─────────────────────────────────' && tail -f '$STATUS_FILE'" C-m

    # Pane 0 (左上): Orchestrator（メイン制御）
    tmux send-keys -t "$SESSION:0.0" "cd '$SWARM_DIR' && bash scripts/orchestrator.sh watch" C-m

    # フォーカスを Orchestrator ペインに設定
    tmux select-pane -t "$SESSION:0.0"

    # ────────────────────────────────────────
    # セッションにアタッチ
    # ────────────────────────────────────────
    echo "✅ Agent Team 準備完了！"
    echo ""
    echo "💡 使い方:"
    echo "   1. 左上の ORCHESTRATOR ペインの指示に従ってください"
    echo "   2. 別ターミナルで shared/TASK.md を編集してタスクを投入します"
    echo "      例: echo 'FizzBuzzを実装して' > shared/TASK.md"
    echo "   3. 各エージェントが自動的に連鎖実行されます"
    echo ""
    echo "   tmux をデタッチ: Ctrl+B → D"
    echo "   tmux に再アタッチ: tmux attach -t $SESSION"
    echo ""

    tmux attach -t "$SESSION"
}

main "$@"
