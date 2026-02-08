# Gemini Agent Team 共通設定

このファイルは Gemini CLI が読み込む共通ルールです。  
エージェントは以下の方針に従って出力してください。

---

## 共通方針

- 出力は日本語
- 余計なファイルを作成しない
- 機密情報（APIキー等）を出力しない
- `docs/spec.md` と `README.md` を仕様の一次情報として参照する

---

## 共有ファイルの役割

- `shared/TASK.md`：ユーザーの指示
- `shared/REQUIREMENTS.md`：Analyst の要件整理
- `shared/DISCUSSION.md`：設計ディスカッション（任意）
- `shared/PLAN.md`：Architect の設計
- `shared/CODE_DRAFT.md`：Engineer の実装
- `shared/REVIEW.md`：Reviewer のレビュー

---

## 重要な制約

- `ENABLE_ANALYST` / `ENABLE_DISCUSSION` / `ENABLE_TASK_QUEUE` の設定に従う
- 生成物はプロジェクト直下の `shared/` 配下のみに書き込む（パス固定）

