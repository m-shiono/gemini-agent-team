# Gemini Agent Team 共通指示

このファイルは全エージェントが従う共通ルールです。

---

## 共通方針

- 出力は日本語
- 指定された出力先ファイル以外を作成・変更しない
- 機密情報（APIキー等）を出力に含めない

---

## エージェント構成と役割

| エージェント | 役割 |
| --- | --- |
| **Analyst** | ユーザーの要望を仕様検討し、要件定義とタスク分解を行う |
| **Architect** | 要件・タスクに基づき、技術設計書を作成する |
| **Engineer** | 設計書に従い、コードを実装する |
| **Reviewer** | 実装コードを要件・設計に基づきレビューする |
| **Explorer** | コードベースを調査し、関連情報を収集する |

---

## パイプライン

```
REQUEST.md（ユーザーの要望）
    │
    ▼
Analyst → REQUIREMENTS.md（要件定義）
        → TASK.md（タスク分解）
    │
    ▼  ※ ENABLE_DISCUSSION=true の場合
Architect ⇄ Engineer ⇄ Reviewer → DISCUSSION.md（設計ディスカッション）
    │
    ▼
Architect → PLAN.md（設計書）
    │
    ▼
Engineer → CODE_DRAFT.md（実装）
    │
    ▼
Reviewer → REVIEW.md（レビュー）
    │
    ├─ LGTM → 完了
    └─ NEEDS_REVISION → Engineer に差し戻し（最大 MAX_REVIEW_ITERATIONS 回）
```

---

## プロジェクトファイル

各プロジェクトの作業ファイルは `project/<プロジェクト名>/` 配下に配置されます。  
エージェントの生成物はこのディレクトリ内のみに書き込んでください。

| ファイル | 作成者 | 用途 |
| --- | --- | --- |
| `REQUEST.md` | ユーザー | 生の要望・依頼内容 |
| `REQUIREMENTS.md` | Analyst | 機能要件・非機能要件の定義 |
| `TASK.md` | Analyst | 仕様検討後の構造化タスク一覧 |
| `DISCUSSION.md` | Architect/Engineer/Reviewer | 設計ディスカッション（任意） |
| `PLAN.md` | Architect | 技術設計書 |
| `CODE_DRAFT.md` | Engineer | 実装コード |
| `REVIEW.md` | Reviewer | レビュー結果と判定 |

---

## フォルダ構成

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
├── scripts/                 # パイプライン制御スクリプト
├── project/                 # プロジェクト作業ディレクトリ
│   └── <プロジェクト名>/
│       ├── REQUEST.md
│       ├── REQUIREMENTS.md
│       ├── TASK.md
│       ├── DISCUSSION.md
│       ├── PLAN.md
│       ├── CODE_DRAFT.md
│       └── REVIEW.md
├── logs/                    # 実行ログ
├── config.sh
└── gemini.md                # このファイル（共通指示）
```

---

## 重要な制約

- 自分の役割で指定された出力先ファイルのみに書き込むこと
- 他のエージェントの出力ファイルを上書きしないこと
- 推測や仮定を含む場合は必ず明示すること
