# Gemini Agent Team Controller

Claude Code の Agent Teams 機能を **Gemini CLI + tmux** で再現するシステムです。

## アーキテクチャ

```
┌─────────────────────┬─────────────────────┬─────────────────────┐
│ 🎮 ORCHESTRATOR     │ 🧭 ANALYST          │ 📐 ARCHITECT        │
│  パイプライン制御     │  要件整理ログ        │  設計ログ            │
├─────────────────────┼─────────────────────┼─────────────────────┤
│ 🔨 ENGINEER         │ 🔍 REVIEWER         │ 📊 STATUS           │
│  実装ログ            │  レビューログ        │  ステータスログ      │
└─────────────────────┴─────────────────────┴─────────────────────┘
```

### パイプラインフロー

```
project/<プロジェクト名>/REQUEST.md (ユーザーの要望)
    │
    ▼
┌─────────┐
│Analyst   │──→ REQUIREMENTS.md (要件定義)
│          │──→ TASK.md (タスク分解)
└─────────┘
    │
    ▼  (ENABLE_DISCUSSION=true の場合)
┌─────────────────────────────────────────┐
│ Architect ⇄ Engineer ⇄ Reviewer        │
│   設計ディスカッション → DISCUSSION.md   │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────┐
│Architect │──→ PLAN.md (設計書)
└─────────┘
    │
    ▼
┌─────────┐
│Engineer  │──→ CODE_DRAFT.md (コード)
└─────────┘      ← REVIEW.md (フィードバック)
    │
    ▼
┌─────────┐
│Reviewer  │──→ REVIEW.md
└─────────┘
    │
    ├─ LGTM → 完了！
    └─ NEEDS_REVISION → Engineer に差し戻し（最大N回）
```

## セットアップ

### 1. 必要なソフトウェア

```bash
# Gemini CLI (必須) - Node.js 18+ が必要
npm install -g @google/gemini-cli

# tmux (必須)
brew install tmux        # macOS
sudo apt install tmux    # Linux

# macOS のみ: timeout コマンド (推奨)
brew install coreutils
```

### 2. 認証設定

```bash
# 方法A: API キー
export GEMINI_API_KEY='your-api-key-here'

# 方法B: Gemini CLI ログイン（初回起動時にブラウザ認証）
gemini

# 方法C: gcloud 認証
gcloud auth application-default login
```

### 3. 設定

```bash
cp .env.example .env
# .env を編集して値を設定（PROJECT_NAME など）
chmod +x start-agent-team.sh scripts/orchestrator.sh scripts/gemini_runner.sh
```

### 4. 簡易チェック（任意）

```bash
bash scripts/quickcheck.sh
```

## 使い方

### 起動

```bash
# デフォルトプロジェクト名で起動
./start-agent-team.sh

# プロジェクト名を指定して起動
PROJECT_NAME=my-app ./start-agent-team.sh
```

### リクエストの投入

別ターミナルから:

```bash
cat > project/default/REQUEST.md << 'EOF'
Python で FizzBuzz を計算するクラスを作成してください。
- 1から100までの数値を処理
- 単体テスト（pytest）も含める
- type hints を使用すること
EOF
```

**フロー:**
1. Analyst が REQUEST.md を読み、仕様検討・タスク分解を実施
2. REQUIREMENTS.md（要件定義）と TASK.md（タスク分解）を生成
3. Architect → Engineer → Reviewer のパイプラインが自動実行

### ステータス確認

```bash
bash scripts/status.sh
```

### 単発実行（ウォッチモードなし）

```bash
bash scripts/orchestrator.sh run
```

### 成果物の確認

```bash
cat project/default/REQUEST.md       # ユーザーの要望
cat project/default/REQUIREMENTS.md  # 要件定義（Analyst）
cat project/default/TASK.md          # タスク分解（Analyst）
cat project/default/PLAN.md          # 設計書（Architect）
cat project/default/CODE_DRAFT.md    # 生成コード（Engineer）
cat project/default/REVIEW.md        # レビュー結果（Reviewer）
```

## 設定

`.env.example` を `.env` にコピーして値を設定してください。

| 変数名 | デフォルト値 | 説明 |
|--------|-------------|------|
| `PROJECT_NAME` | `default` | プロジェクト名（作業ディレクトリ名） |
| `GEMINI_API_KEY` | - | API キー |
| `GEMINI_MODEL` | `gemini-2.5-flash` | 使用するモデル |
| `MAX_REVIEW_ITERATIONS` | `2` | レビューループの最大回数 |
| `AGENT_TIMEOUT` | `180` | エージェントのタイムアウト（秒） |
| `ENABLE_ANALYST` | `true` | Analyst フェーズを有効化 |
| `ENABLE_DISCUSSION` | `false` | 設計ディスカッションを有効化 |
| `DISCUSSION_ROUNDS` | `1` | ディスカッション反復回数 |
| `WATCH_POLL_INTERVAL` | `2` | ポーリング間隔（秒） |
| `SWARM_SESSION` | `gemini-agent-team` | tmux セッション名 |

## ディレクトリ構成

```
gemini-agent-team/
├── agents/                  # エージェントの役割定義（システムプロンプト）
│   ├── analyst.md
│   ├── architect.md
│   ├── architect_discuss.md
│   ├── engineer.md
│   ├── engineer_discuss.md
│   ├── reviewer.md
│   ├── reviewer_discuss.md
│   └── explorer.md
├── scripts/
│   ├── gemini_runner.sh     # Gemini CLI ラッパー
│   ├── orchestrator.sh      # パイプライン制御
│   ├── quickcheck.sh        # 簡易チェック
│   └── status.sh            # ステータス表示
├── project/                 # プロジェクト作業ディレクトリ
│   └── <プロジェクト名>/     # プロジェクトごとのワークスペース
│       ├── REQUEST.md       # ユーザーの要望（入力）
│       ├── REQUIREMENTS.md  # 要件定義（Analyst 出力）
│       ├── TASK.md          # タスク分解（Analyst 出力）
│       ├── DISCUSSION.md    # 設計ディスカッション
│       ├── PLAN.md          # 設計書（Architect 出力）
│       ├── CODE_DRAFT.md    # 実装コード（Engineer 出力）
│       └── REVIEW.md        # レビュー結果（Reviewer 出力）
├── logs/                    # リアルタイムログ
├── config.sh
├── .env.example
├── start-agent-team.sh
└── gemini.md
```

## tmux 操作チートシート

| 操作 | キー |
|------|------|
| デタッチ | `Ctrl+B` → `D` |
| 再アタッチ | `tmux attach -t gemini-agent-team` |
| ペイン間移動 | `Ctrl+B` → 矢印キー |
| セッション終了 | `tmux kill-session -t gemini-agent-team` |
| ペインをズーム | `Ctrl+B` → `Z` |
| スクロール | `Ctrl+B` → `[` → 矢印/PgUp → `Q` で終了 |
