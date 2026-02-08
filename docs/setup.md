# Gemini 設定ガイド

このプロジェクトで使用する Gemini API の設定方法をまとめます。

---

## 1. .env での設定

`config.sh` は `.env` を自動で読み込みます。  
`/.env.example` を `.env` にコピーして値を設定してください。

```
cp .env.example .env
```

---

## 2. 認証モード

`GEMINI_AUTH_MODE` で認証方式を指定します。

- `auto` : APIキー → Vertex AI → ADC の順で自動判定
- `api_key` : Google AI Studio の API キー
- `vertex_ai` : Google Cloud Vertex AI
- `adc` : Application Default Credentials

### api_key モード

```
GEMINI_AUTH_MODE=api_key
GEMINI_API_KEY=your-api-key
```

### vertex_ai モード

```
GEMINI_AUTH_MODE=vertex_ai
GEMINI_GCP_PROJECT=your-project-id
GEMINI_GCP_LOCATION=us-central1
```

### adc モード

```
GEMINI_AUTH_MODE=adc
GOOGLE_APPLICATION_CREDENTIALS=/path/to/credentials.json
```

---

## 3. モデル指定

```
GEMINI_MODEL=gemini-2.5-flash
```

---

## 4. 動作確認

起動スクリプトで事前チェックが行われます。

```
bash start-agent-team.sh
```

