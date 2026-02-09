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
    ├─ NEEDS_REVISION → Engineer に差し戻し（指摘を反映して再実装）
    └─ NEEDS_DESIGN_REVISION → Architect に差し戻し（設計を修正）→ 続けて Engineer → Reviewer
    ※ 上記のループは最大 MAX_REVIEW_ITERATIONS 回まで
```

---

## プロジェクトファイル

各プロジェクトの作業ファイルは `project/<プロジェクト名>/` 配下に配置されます。  
エージェントの生成物はこのディレクトリ内のみに書き込んでください。

| ファイル | 作成者 | 用途 |
| --- | --- | --- |
| `REQUEST.md` | ユーザー | 生の要望・依頼内容 |
| `REQUIREMENTS.md` | Analyst | 機能要件・非機能要件の定義 |
| `TASK.md` | Analyst が作成、Architect/Engineer が進捗更新 | 仕様検討後の構造化タスク一覧。フェーズ完了時に該当タスクを `[x]` に更新する |
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

## TASK.md の進捗管理

- **Analyst**: 初回作成（全タスクを `[ ]` で記載）。
- **Architect**: 設計書（PLAN.md）を出したら、TASK.md の「設計」フェーズに該当するタスクを `[x]` に更新して出力に含める。
- **Engineer**: 実装（CODE_DRAFT.md）を出したら、TASK.md の「実装」フェーズに該当するタスクを `[x]` に更新して出力に含める。

Architect と Engineer は、メイン成果物（PLAN.md / CODE_DRAFT.md）の直後に**1行だけ**区切り `--- TASK.md ---` を書き、その後に更新した TASK.md の全文を続ける。オーケストレータがこの区切りで分割し、それぞれのファイルに保存する。

---

## 重要な制約

- 自分の役割で指定された出力先ファイルのみに書き込むこと
- 他のエージェントの出力ファイルを上書きしないこと
- 推測や仮定を含む場合は必ず明示すること
