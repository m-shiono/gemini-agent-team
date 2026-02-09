# セットアップガイド

## 1. Gemini CLI のインストール

Node.js 18 以上が必要です。

```bash
npm install -g @google/gemini-cli
```

## 2. 認証設定

以下のいずれかで認証します:

```bash
# API キー
export GEMINI_API_KEY='your-api-key'

# または Gemini CLI のログイン
gemini    # 初回起動時にブラウザ認証

# または gcloud 認証
gcloud auth application-default login
```

## 3. 設定

```bash
cp .env.example .env
# .env を編集
```

## 4. macOS ユーザー向け

```bash
brew install tmux coreutils
```

## 5. 動作確認

```bash
bash scripts/quickcheck.sh
./start-agent-team.sh
```
