# Gemini Agent Team - System Specification

本ドキュメントは本システムの仕様をまとめたものです。

---

## 目的

Claude Code の Agent Teams に相当する開発体験を、Gemini API と tmux で提供する。

---

## 全体構成

- **Orchestrator**: パイプライン制御と監視
- **Analyst**: ふわっとした要件を仕様検討・タスク分解
- **Architect**: 設計書の作成
- **Engineer**: 実装の作成
- **Reviewer**: レビューと差し戻し

### tmux レイアウト

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

---

## パイプライン

```
project/<プロジェクト名>/REQUEST.md (ユーザーの要望)
    │
    ▼
Analyst    → REQUIREMENTS.md (要件定義)
           → TASK.md (タスク分解)
    │
    ▼
Discussion → DISCUSSION.md (任意)
    │
    ▼
Architect  → PLAN.md (設計書)
    │
    ▼
Engineer   → CODE_DRAFT.md (実装)
    │
    ▼
Reviewer   → REVIEW.md (レビュー)
```

- Reviewer が `NEEDS_REVISION` を含む場合は Engineer に差し戻し。
- 最大 `MAX_REVIEW_ITERATIONS` までループ。

---

## 入出力・プロジェクトファイル

各プロジェクトのファイルは `project/<プロジェクト名>/` 配下に配置されます。

| ファイル | 用途 |
| --- | --- |
| `REQUEST.md` | ユーザーの要望（生の依頼内容） |
| `REQUIREMENTS.md` | Analyst の要件定義 |
| `TASK.md` | Analyst のタスク分解（仕様検討後の構造化タスク） |
| `DISCUSSION.md` | 設計ディスカッション（任意） |
| `PLAN.md` | Architect の設計書 |
| `CODE_DRAFT.md` | Engineer の実装 |
| `REVIEW.md` | Reviewer のレビュー |

---

## 主要コンポーネント

### `scripts/orchestrator.sh`

- ファイル監視（inotify + ポーリング）
- 安定化待ち（デバウンス、安定ハッシュ）
- 二重起動ロック（flock）
- パイプライン再試行
- Analyst/Discussion フェーズ
- タスクキュー自動取得
- 履歴保存とローテーション
- Webhook 通知
- ステータス出力
- メンテナンスモード

### `scripts/gemini_runner.sh`

- Gemini CLI 呼び出し
- 認証モードの自動判定（`auto`）
- ストリーミング出力
- ログのマスキング

### `start-agent-team.sh`
### Discussion Agents

- `agents/architect_discuss.md`
- `agents/engineer_discuss.md`
- `agents/reviewer_discuss.md`


- tmux セッション構築
- ペインにログ表示を割当
- Orchestrator 起動

---

## 認証モード

| モード | 説明 |
| --- | --- |
| `auto` | 自動判定（APIキー → Vertex AI → ADC） |
| `api_key` | Google AI Studio の API キー |
| `vertex_ai` | Google Cloud Vertex AI |
| `adc` | Application Default Credentials |

---

## 通知

Webhook による通知をサポート。

- `generic`
- `slack`
- `discord`
- `teams`
- `teams_adaptive`

owner 別の通知先は `WEBHOOK_OWNER_MAP` で設定できます。

---

## 履歴・ログ

- 実行履歴: `logs/runs/run-<id>/`
- エラー集約: `ERROR_REPORT.md`
- ステータス: `logs/status.json`
- マスキング: `REDACT_VALUES` に指定した値を置換

---

## セキュリティ

- `umask 077` をデフォルト適用
- 重要ファイルの権限を制限 (`SECURE_FILES=true`)
- タスク内の機密情報検知 (`TASK_SECRET_REGEX`)

## タスクキュー（任意）

`tasks/inbox` にタスクファイルを置くと、待機中に自動取得して処理します。

### 優先度

ファイル名に `P1_`〜`P9_` を付けると優先度で処理されます。  
数字が小さいほど優先されます（例: `P1_task.md`）。
YAML front-matter の `priority` がある場合はそちらを優先します。

### メタデータ

YAML front-matter で `title`, `owner`, `due` を指定できます。
`owner` は `TASK_QUEUE_OWNER_FILTER` によるフィルタ対象です。
`due` は `%Y-%m-%d` と `%Y-%m-%d %H:%M` をサポートします。
`TASK_QUEUE_OWNER_SUBDIR=true` の場合は `tasks/inbox/<owner>/` も対象にします。
`TASK_QUEUE_DUE_TZ` でタイムゾーンを指定できます（例: `+09:00`）。
`TASK_QUEUE_DUE_WARN_HOURS` で時間単位の警告が可能です。
`TASK_QUEUE_OWNER_AUTO_DIR=true` の場合は owner サブディレクトリを自動作成します。
`TASK_QUEUE_DUE_LABEL_PREFIX` で期限ラベルの接頭辞を変更できます。
`TASK_QUEUE_OVERDUE_ACTION=fail` で期限超過タスクを自動的に失敗扱いにできます（デフォルト無効）。
`WEBHOOK_NOTIFY_OVERDUE=true` で期限超過通知を有効化できます（デフォルト無効）。
`WEBHOOK_OVERDUE_URL` で期限超過専用の通知先を指定できます。
`TASK_QUEUE_OVERDUE_REQUEUE=true` で期限超過時に再投入できます（デフォルト無効）。

### ステータス管理

- 取得時: `tasks/in-progress/`
- 成功時: `tasks/done/`
- 失敗時: `tasks/failed/`
- `TASK_QUEUE_REQUEUE_ON_FAILURE=true` の場合は失敗時に `tasks/inbox` へ再投入
 - 失敗時は `.reason.md` に原因概要を保存

### Owner 補正

`TASK_QUEUE_OWNER_PRIORITY_BIAS` で担当者ごとに優先度補正できます。  
例: `alice=-1,bob=1`（数値が小さいほど優先）。

---

## 代表的な設定

| 変数 | 役割 |
| --- | --- |
| `PROJECT_NAME` | プロジェクト名 |
| `GEMINI_AUTH_MODE` | 認証モード |
| `GEMINI_API_KEY` | API キー |
| `GEMINI_GCP_PROJECT` | Vertex AI プロジェクト |
| `GEMINI_GCP_LOCATION` | Vertex AI リージョン |
| `MAX_REVIEW_ITERATIONS` | レビュー反復 |
| `AGENT_TIMEOUT` | タイムアウト |
| `WEBHOOK_TEMPLATE` | 通知テンプレート |
| `STATUS_FILE` | ステータス出力 |
| `MAINTENANCE_MODE` | メンテナンス制御 |
| `ENABLE_ANALYST` | Analyst フェーズ |
| `ENABLE_DISCUSSION` | 設計ディスカッション |
| `ENABLE_TASK_QUEUE` | タスクキュー自動取得 |
| `TASK_QUEUE_YAML_PRIORITY_KEY` | YAML の優先度キー |
| `TASK_QUEUE_YAML_TITLE_KEY` | YAML のタイトルキー |
| `TASK_QUEUE_REQUEUE_ON_FAILURE` | 失敗時の再投入 |
