# Gemini Agent Team Controller

Claude Code の Agent Teams 機能を **Gemini API + tmux** で再現するシステムです。

## アーキテクチャ

```
┌─────────────────────┬─────────────────────┬─────────────────────┐
│ 🎮 ORCHESTRATOR     │ 🧭 ANALYST          │ 📐 ARCHITECT        │
│  パイプライン制御     │  要件整理ログ        │  設計ログ (リアルタイム) │
│  ファイル変更監視     │  tail -f analyst.log│  tail -f architect.log│
├─────────────────────┼─────────────────────┼─────────────────────┤
│ 🔨 ENGINEER         │ 🔍 REVIEWER         │ 📊 STATUS           │
│  実装ログ (リアルタイム) │  レビューログ        │  status.json 監視   │
│  tail -f engineer.log│  tail -f reviewer.log│  tail -f status.json│
└─────────────────────┴─────────────────────┴─────────────────────┘
```

### tmux レイアウトの説明

- **左上: ORCHESTRATOR**  
  `scripts/orchestrator.sh` が常駐し、TASK の変更監視とパイプライン制御を行います。
- **中上: ANALYST**  
  `logs/analyst.log` をリアルタイム表示（要件整理フェーズ）。
- **右上: ARCHITECT**  
  `logs/architect.log` をリアルタイム表示（設計フェーズの出力）。
- **左下: ENGINEER**  
  `logs/engineer.log` をリアルタイム表示（実装フェーズの出力）。
- **中下: REVIEWER**  
  `logs/reviewer.log` をリアルタイム表示（レビュー結果）。
- **右下: STATUS**  
  `logs/status.json` をリアルタイム表示（最新状態）。

### パイプラインフロー

```
TASK.md (ユーザー入力)
    │
    ▼
┌─────────┐
│Analyst   │──→ REQUIREMENTS.md (要件整理)
└─────────┘
    │
    ▼
┌─────────┐
│Architect │──→ PLAN.md (設計書)
└─────────┘
    │
    ▼
┌─────────┐
│Engineer  │──→ CODE_DRAFT.md (コード)
└─────────┘      ← REVIEW.md (フィードバックがあれば)
    │
    ▼
┌─────────┐
│Reviewer  │──→ REVIEW.md
└─────────┘
    │
    ├─ LGTM → 完了！
    └─ NEEDS_REVISION → Engineer に差し戻し（最大N回）
```

`ENABLE_DISCUSSION=true` の場合、Analyst と Architect の間にディスカッションが入ります。

## セットアップ

### 1. 必要なソフトウェア

```bash
# tmux (必須)
sudo apt install tmux

# Python 3 (必須)
# ほとんどの環境にプリインストール済み

# inotify-tools (推奨: 効率的なファイル監視)
sudo apt install inotify-tools
```

### 2. Python パッケージ

```bash
pip install -r requirements.txt
```

### 3. 認証設定

認証モードは **auto / api_key / vertex_ai / adc** の4つです。  
デフォルトは `auto` で、次の順で自動判定します:

1. `GEMINI_API_KEY` があれば **api_key**
2. `GEMINI_GCP_PROJECT` / `GEMINI_GCP_LOCATION` があれば **vertex_ai**
3. `GOOGLE_APPLICATION_CREDENTIALS` または gcloud ADC があれば **adc**

#### モードA: API キー（Google AI Studio）

個人開発者向け。[Google AI Studio](https://aistudio.google.com/apikey) で無料の API キーを取得できます。

```bash
export GEMINI_AUTH_MODE=api_key          # デフォルトなので省略可
export GEMINI_API_KEY='your-api-key-here'
```

#### モードB: Vertex AI（Google Cloud）

Google One AI Premium サブスクリプションや企業の Google Cloud 環境で利用する場合。

```bash
# gcloud CLI のインストールと認証
gcloud auth application-default login

export GEMINI_AUTH_MODE=vertex_ai
export GEMINI_GCP_PROJECT='your-project-id'
export GEMINI_GCP_LOCATION='us-central1'     # 省略可（デフォルト: us-central1）
```

#### モードC: ADC（Application Default Credentials）

`gcloud auth application-default login` 済みの環境で利用します。  
プロジェクトは `GEMINI_GCP_PROJECT` または gcloud の default project から取得されます。

```bash
gcloud auth application-default login
export GEMINI_AUTH_MODE=adc

# 明示的に指定したい場合
export GEMINI_GCP_PROJECT='your-project-id'
```

### 4. 実行権限の付与

```bash
chmod +x start-agent-team.sh scripts/orchestrator.sh
```

### 5. 簡易チェック（任意）

```bash
bash scripts/quickcheck.sh
```

### 5. Webhook 通知（任意）

#### Generic（デフォルト）
```bash
export WEBHOOK_URL='https://example.com/webhook'
export WEBHOOK_TEMPLATE=generic
```

#### Slack Incoming Webhook
```bash
export WEBHOOK_URL='https://hooks.slack.com/services/xxx/yyy/zzz'
export WEBHOOK_TEMPLATE=slack
```

#### Discord Webhook
```bash
export WEBHOOK_URL='https://discord.com/api/webhooks/xxx/yyy'
export WEBHOOK_TEMPLATE=discord
```

#### Microsoft Teams Webhook
```bash
export WEBHOOK_URL='https://outlook.office.com/webhook/xxx/yyy'
export WEBHOOK_TEMPLATE=teams
```

#### Microsoft Teams Webhook (Adaptive Card)
```bash
export WEBHOOK_URL='https://outlook.office.com/webhook/xxx/yyy'
export WEBHOOK_TEMPLATE=teams_adaptive
```

## 使い方

### 起動

```bash
./start-agent-team.sh
```


tmux の4分割画面が立ち上がります。

### ステータス確認

```bash
bash scripts/status.sh
```

### タスクの投入

**方法A: 別ターミナルから**

```bash
cat > shared/TASK.md << 'EOF'
Python で FizzBuzz を計算するクラスを作成してください。
- 1から100までの数値を処理
- 単体テスト（pytest）も含める
- type hints を使用すること
EOF
```

**方法B: tmux 内で**

Orchestrator ペインで `Ctrl+C` して一時停止し、エディタで編集：

```bash
nano shared/TASK.md
# 編集後、オーケストレータを再起動:
bash scripts/orchestrator.sh watch
```

### タスクキューから自動取得（オプション）

デフォルトでは無効です。`tasks/inbox` に置かれたタスクを自動的に取得して処理します。  
有効化する場合は `ENABLE_TASK_QUEUE=true` を設定してください。

**優先度付け**: ファイル名に `P1_`〜`P9_` を付けると優先度で処理されます（数字が小さいほど優先）。  
YAML front-matter で `priority` を指定することもできます（ファイル名より優先）。
`title`, `owner`, `due` も指定可能で、ステータスに反映されます。
`owner` は `TASK_QUEUE_OWNER_FILTER` に一致するものだけを処理できます。
`TASK_QUEUE_OWNER_SUBDIR=true` の場合は `tasks/inbox/<owner>/` も対象にします。
`TASK_QUEUE_OWNER_PRIORITY_BIAS="alice=-1,bob=1"` のように担当者ごとに補正できます。
`TASK_QUEUE_OWNER_AUTO_DIR=true` の場合、必要なサブディレクトリを自動作成します。
期限超過時の動作は `TASK_QUEUE_OVERDUE_ACTION=warn|fail` で制御します。
期限超過時の通知は `WEBHOOK_NOTIFY_OVERDUE=true` で制御します。
期限超過専用の通知先は `WEBHOOK_OVERDUE_URL` で指定できます。
期限超過時の再投入は `TASK_QUEUE_OVERDUE_REQUEUE=true` で制御します。

**ステータス管理**: 取得されたタスクは `in-progress` に移動され、成功時は `done`、失敗時は `failed` に移動します。
再投入したい場合は `TASK_QUEUE_REQUEUE_ON_FAILURE=true` を設定してください。
失敗時は `.reason.md` が生成され、原因の概要が保存されます。

```bash
export ENABLE_TASK_QUEUE=true
mkdir -p tasks/inbox tasks/in-progress tasks/done tasks/failed

# タスクを投入（ファイル名は任意）
cat > tasks/inbox/P1_task-001.md << 'EOF'
---
title: ログイン機能
priority: 1
owner: alice
due: 2026-02-15
---
ログイン機能を追加して。
EOF
```

### 設計ディスカッション（オプション）

デフォルトでは無効です。Analyst の要件整理後に  
Architect/Engineer/Reviewer が `DISCUSSION.md` を通じて会話し、設計を深掘りします。

```bash
export ENABLE_DISCUSSION=true
export DISCUSSION_ROUNDS=1
```

### 単発実行（ウォッチモードなし）

```bash
bash scripts/orchestrator.sh run
```

### 成果物の確認

```bash
cat shared/REQUIREMENTS.md  # 要件整理（Analyst）
cat shared/DISCUSSION.md    # 設計ディスカッション（任意）
cat shared/PLAN.md        # 設計書
cat shared/CODE_DRAFT.md  # 生成されたコード
cat shared/REVIEW.md      # レビュー結果
```

### 要件整理（Analyst）を単独で実行

```bash
python3 scripts/gemini_runner.py \
  --role agents/analyst.md \
  --input shared/TASK.md \
  --output shared/REQUIREMENTS.md \
  --log logs/analyst.log
```

## 設定

`config.sh` は `.env` があれば自動で読み込みます。  
`./.env.example` を `.env` にコピーして値を設定してください。  
別パスを使う場合は `ENV_FILE` を指定できます。

詳細な設定手順は `docs/setup.md` を参照してください。

`config.sh` で以下の項目を変更できます：

| 変数名 | デフォルト値 | 説明 |
|--------|-------------|------|
| `GEMINI_AUTH_MODE` | `auto` | 認証モード (`auto` / `api_key` / `vertex_ai` / `adc`) |
| `GEMINI_API_KEY` | - | API キー（`api_key` モード時に必須） |
| `GEMINI_GCP_PROJECT` | - | GCP プロジェクトID（`vertex_ai` モード時に必須） |
| `GEMINI_GCP_LOCATION` | `us-central1` | GCP リージョン（`vertex_ai` モード時） |
| `GOOGLE_APPLICATION_CREDENTIALS` | - | ADC 用のサービスアカウントJSON（任意） |
| `GEMINI_MODEL` | `gemini-2.5-flash` | 使用するモデル |
| `MAX_REVIEW_ITERATIONS` | `2` | レビューループの最大回数 |
| `AGENT_TIMEOUT` | `180` | エージェントのタイムアウト（秒） |
| `TASK_DEBOUNCE_SECONDS` | `0.5` | 監視イベント後の待機時間 |
| `TASK_STABLE_CHECKS` | `2` | ハッシュが安定したと判断する回数 |
| `TASK_STABLE_INTERVAL` | `0.5` | 安定判定のチェック間隔（秒） |
| `WATCH_POLL_INTERVAL` | `2` | inotify 非対応時のポーリング間隔（秒） |
| `SWARM_LOCK_FILE` | `logs/agent-team.lock` | 二重起動防止ロック |
| `HISTORY_DIR` | `logs/runs` | 実行履歴の保存先 |
| `KEEP_RUNS` | `20` | 履歴を保持する最大件数 |
| `PIPELINE_RETRY_COUNT` | `1` | パイプライン再試行回数 |
| `PIPELINE_RETRY_DELAY` | `3` | 再試行までの待機秒数 |
| `ENABLE_ANALYST` | `true` | Analyst フェーズを有効化 |
| `ENABLE_DISCUSSION` | `false` | 設計ディスカッションを有効化 |
| `DISCUSSION_ROUNDS` | `1` | ディスカッション反復回数 |
| `DISCUSSION_FILE` | `shared/DISCUSSION.md` | ディスカッション出力先 |
| `ENABLE_TASK_QUEUE` | `false` | タスクキュー自動取得 |
| `TASK_QUEUE_DIR` | `tasks/inbox` | タスク受け取りディレクトリ |
| `TASK_QUEUE_PATTERN` | `*.md` | タスクファイルのパターン |
| `TASK_QUEUE_PRIORITY_REGEX` | `^P([0-9])_` | 優先度判定の正規表現 |
| `TASK_QUEUE_DEFAULT_PRIORITY` | `5` | 優先度のデフォルト値 |
| `TASK_QUEUE_YAML_PRIORITY_KEY` | `priority` | YAML の優先度キー |
| `TASK_QUEUE_YAML_TITLE_KEY` | `title` | YAML のタイトルキー |
| `TASK_QUEUE_YAML_OWNER_KEY` | `owner` | YAML の担当者キー |
| `TASK_QUEUE_YAML_DUE_KEY` | `due` | YAML の期限キー |
| `TASK_QUEUE_OWNER_FILTER` | - | 指定オーナーのみ処理 |
| `TASK_QUEUE_DUE_WARN_DAYS` | `0` | 期限の警告日数 |
| `TASK_QUEUE_DUE_WARN_HOURS` | `0` | 期限の警告時間（時間単位） |
| `TASK_QUEUE_OWNER_PRIORITY_BIAS` | - | 担当者ごとの優先度補正 |
| `TASK_QUEUE_DUE_FORMATS` | `%Y-%m-%d,%Y-%m-%d %H:%M` | 期限フォーマット |
| `TASK_QUEUE_DUE_TZ` | `local` | 期限のタイムゾーン（例: `+09:00`） |
| `TASK_QUEUE_OWNER_SUBDIR` | `false` | owner別サブディレクトリを有効化 |
| `TASK_QUEUE_OWNER_AUTO_DIR` | `true` | ownerサブディレクトリ自動作成 |
| `TASK_QUEUE_DUE_LABEL_PREFIX` | `DUE_` | 期限ラベルの接頭辞 |
| `TASK_QUEUE_OVERDUE_ACTION` | `warn` | 期限超過時の動作（warn/fail） |
| `TASK_QUEUE_OVERDUE_REQUEUE` | `false` | 期限超過時に再投入するか |
| `WEBHOOK_NOTIFY_OVERDUE` | `false` | 期限超過時の通知 |
| `WEBHOOK_OVERDUE_URL` | - | 期限超過通知のWebhook |
| `TASK_QUEUE_INPROGRESS_DIR` | `tasks/in-progress` | 取り込み中タスク |
| `TASK_QUEUE_DONE_DIR` | `tasks/done` | 完了タスク |
| `TASK_QUEUE_FAILED_DIR` | `tasks/failed` | 失敗タスク |
| `TASK_QUEUE_REQUEUE_ON_FAILURE` | `false` | 失敗時に再投入するか |
| `TASK_QUEUE_RETRY_MAX` | `3` | 再投入の最大回数 |
| `TASK_QUEUE_RETRY_BACKOFF_BASE` | `30` | 再投入の基準秒数 |
| `SWARM_SESSION` | `gemini-agent-team` | tmux セッション名 |
| `REDACT_VALUES` | `GEMINI_API_KEY` | マスキング対象（カンマ区切り） |
| `REDACT_REPLACEMENT` | `[REDACTED]` | マスキング置換文字 |
| `WEBHOOK_URL` | - | 実行結果を通知するWebhook URL |
| `WEBHOOK_TIMEOUT` | `5` | Webhook 通知タイムアウト（秒） |
| `WEBHOOK_INCLUDE_TASK` | `false` | 通知にタスク先頭行を含めるか |
| `WEBHOOK_TEMPLATE` | `generic` | `generic` / `slack` / `discord` / `teams` / `teams_adaptive` |
| `WEBHOOK_INCLUDE_SUMMARY` | `true` | 完了時サマリを通知に含める |
| `TASK_SUMMARY_MAX_CHARS` | `280` | サマリの最大文字数 |
| `WEBHOOK_OWNER_MAP` | - | owner ごとの Webhook URL マップ |
| `TASK_SECRET_ALLOW` | `false` | 机密情報検知を許可するか |
| `TASK_SECRET_REGEX` | 既定パターン | 机密情報検知の正規表現 |
| `UMASK_VALUE` | `077` | 生成ファイルのデフォルト権限 |
| `SECURE_FILES` | `true` | ログ/履歴の権限を強制的に絞る |
| `STATUS_FILE` | `logs/status.json` | 最新の実行状態を書き出すファイル |
| `MAINTENANCE_MODE` | `false` | `true` の場合は実行を停止 |

## ディレクトリ構成

```
gemini-agent-team/
├── agents/                  # エージェントの役割定義（システムプロンプト）
│   ├── analyst.md           #   要件整理担当
│   ├── architect.md         #   設計担当
│   ├── architect_discuss.md #   設計ディスカッション担当
│   ├── engineer.md          #   実装担当
│   ├── engineer_discuss.md  #   実装ディスカッション担当
│   ├── reviewer.md          #   レビュー担当
│   ├── reviewer_discuss.md  #   レビューディスカッション担当
│   └── explorer.md          #   調査担当（拡張用）
├── scripts/
│   ├── gemini_runner.py     # Gemini API ラッパー（ストリーミング対応）
│   └── orchestrator.sh      # パイプライン制御スクリプト
├── shared/                  # エージェント間の共有ワークスペース
│   ├── TASK.md              #   ユーザーの指示（入力）
│   ├── REQUIREMENTS.md      #   要件整理（Analyst → Architect）
│   ├── DISCUSSION.md         #   設計ディスカッション（任意）
│   ├── PLAN.md              #   設計書（Architect → Engineer）
│   ├── CODE_DRAFT.md        #   コード（Engineer → Reviewer）
│   └── REVIEW.md            #   レビュー結果（Reviewer → Engineer）
├── tasks/                   # タスクキュー（任意）
│   ├── inbox/               #   取得待ちタスク
│   ├── in-progress/         #   取り込み中
│   ├── done/                #   完了
│   ├── failed/              #   失敗
├── logs/                    # エージェントのリアルタイムログ
├── config.sh                # 設定ファイル
├── requirements.txt         # Python 依存パッケージ
├── start-agent-team.sh      # 起動スクリプト
└── docs/spec.md             # システム仕様書
```

## tmux 操作チートシート

| 操作 | キー |
|------|------|
| デタッチ（バックグラウンドに） | `Ctrl+B` → `D` |
| 再アタッチ | `tmux attach -t gemini-agent-team` |
| ペイン間移動 | `Ctrl+B` → 矢印キー |
| セッション終了 | `tmux kill-session -t gemini-agent-team` |
| ペインをズーム | `Ctrl+B` → `Z` |
| スクロール | `Ctrl+B` → `[` → 矢印/PgUp/PgDn → `Q` で終了 |
