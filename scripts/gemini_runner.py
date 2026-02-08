#!/usr/bin/env python3
"""
Gemini Agent Runner
===================
指定された役割（システムプロンプト）でGemini APIを呼び出し、
ストリーミング出力をログとファイルに保存する。

改善点（元の仕様から）:
- 複数入力ファイルによるコンテキスト蓄積
- ストリーミング出力（リアルタイム表示）
- リトライ付きエラーハンドリング
- 適切な終了コード
- google-genai (新SDK) を使用
"""

import os
import sys
import argparse
import time
import signal

from google import genai
from google.genai import types


# --- Constants ---
MAX_RETRIES = 3
RETRY_DELAY_BASE = 2  # seconds (exponential backoff)


def get_redact_values():
    """
    環境変数からマスキング対象の値を取得する。

    REDACT_VALUES はカンマ区切りの文字列として指定可能。
    """
    raw = os.environ.get("REDACT_VALUES", "")
    values = []
    for item in raw.split(","):
        item = item.strip()
        if item:
            values.append(item)

    # APIキーは暗黙的にマスク対象にする
    api_key = os.environ.get("GEMINI_API_KEY")
    if api_key and api_key not in values:
        values.append(api_key)

    return values


def redact_text(text, values, replacement):
    """指定された値をすべて置換してマスクする。"""
    if not text or not values:
        return text
    masked = text
    for val in values:
        if val:
            masked = masked.replace(val, replacement)
    return masked


def setup_signal_handlers():
    """Graceful shutdown on SIGTERM/SIGINT."""
    def handler(signum, frame):
        print("\n[Agent] Interrupted. Exiting gracefully.", flush=True)
        sys.exit(130)
    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)


def read_file_safe(filepath):
    """ファイルを安全に読み込む。存在しない・空の場合はNoneを返す。"""
    try:
        if os.path.exists(filepath) and os.path.getsize(filepath) > 0:
            with open(filepath, "r", encoding="utf-8") as f:
                content = f.read().strip()
            return content if content else None
    except (IOError, OSError) as e:
        print(f"[Warning] Could not read {filepath}: {e}", file=sys.stderr)
    return None


def build_context(input_files):
    """
    複数の入力ファイルからコンテキストを構築する。
    各ファイルの内容を区切り付きで結合し、上流の成果物を全て含める。
    """
    parts = []
    for filepath in input_files:
        content = read_file_safe(filepath)
        if content:
            filename = os.path.basename(filepath)
            parts.append(f"=== {filename} ===\n{content}")

    if not parts:
        return None

    return "\n\n".join(parts)


def resolve_auth_mode():
    """
    認証モードを解決する。

    認証モード (GEMINI_AUTH_MODE):
        auto      : 自動判定（APIキー/Vertex AI/ADC を順に検出）
        api_key   : Google AI Studio の API キーを使用
        vertex_ai : Google Cloud Vertex AI を使用（gcloud 認証が必要）
        adc       : Application Default Credentials を使用

    Returns:
        str: 解決された認証モード (api_key / vertex_ai / adc / none)
    """
    auth_mode = os.environ.get("GEMINI_AUTH_MODE", "auto").lower()

    if auth_mode != "auto":
        return auth_mode

    # 1) API Key があるなら最優先
    if os.environ.get("GEMINI_API_KEY"):
        return "api_key"

    # 2) Vertex AI の明示指定がある場合
    if os.environ.get("GEMINI_GCP_PROJECT") or os.environ.get("GEMINI_GCP_LOCATION"):
        return "vertex_ai"

    # 3) ADC の証明書ファイルがある場合
    if os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
        return "adc"

    # 4) gcloud ADC が設定済みなら ADC とみなす
    try:
        import google.auth
        google.auth.default()
        return "adc"
    except Exception:
        pass

    return "none"


def create_client():
    """
    環境変数に基づいて適切な Gemini クライアントを作成する。

    Returns:
        genai.Client: 初期化されたクライアント
    """
    auth_mode = resolve_auth_mode()

    if auth_mode == "api_key":
        api_key = os.environ.get("GEMINI_API_KEY")
        if not api_key:
            print("[Error] GEMINI_AUTH_MODE=api_key ですが GEMINI_API_KEY が未設定です。",
                  file=sys.stderr)
            print("  → export GEMINI_API_KEY='your-key' を実行してください。",
                  file=sys.stderr)
            return None
        print(f"[Auth] API Key モード (Google AI Studio)", flush=True)
        return genai.Client(api_key=api_key)

    elif auth_mode == "vertex_ai":
        project = os.environ.get("GEMINI_GCP_PROJECT")
        location = os.environ.get("GEMINI_GCP_LOCATION", "us-central1")
        if not project:
            try:
                import google.auth
                _, project = google.auth.default()
            except Exception:
                project = None
        if not project:
            print("[Error] GEMINI_AUTH_MODE=vertex_ai ですがプロジェクトIDが取得できません。",
                  file=sys.stderr)
            print("  → GEMINI_GCP_PROJECT を設定するか、gcloud の default project を設定してください。",
                  file=sys.stderr)
            return None
        print(f"[Auth] Vertex AI モード (project={project}, location={location})",
              flush=True)
        return genai.Client(vertexai=True, project=project, location=location)

    elif auth_mode == "adc":
        print("[Auth] ADC モード (Application Default Credentials)", flush=True)
        print("  → 事前に gcloud auth application-default login が必要です。",
              flush=True)

        project = os.environ.get("GEMINI_GCP_PROJECT")
        location = os.environ.get("GEMINI_GCP_LOCATION", "us-central1")

        if not project:
            try:
                import google.auth
                _, project = google.auth.default()
            except Exception:
                project = None

        if not project:
            print("[Error] ADC モードですがプロジェクトIDが取得できません。", file=sys.stderr)
            print("  → GEMINI_GCP_PROJECT を設定するか、gcloud の default project を設定してください。",
                  file=sys.stderr)
            return None

        return genai.Client(vertexai=True, project=project, location=location)

    elif auth_mode == "none":
        print("[Error] 認証情報が検出できません。", file=sys.stderr)
        print("  → GEMINI_API_KEY または GEMINI_GCP_PROJECT などを設定してください。", file=sys.stderr)
        print("  → もしくは GEMINI_AUTH_MODE を api_key / vertex_ai / adc に明示してください。", file=sys.stderr)
        return None

    else:
        print(f"[Error] 不明な認証モード: {auth_mode}", file=sys.stderr)
        print("  → GEMINI_AUTH_MODE は api_key / vertex_ai / adc のいずれかを指定してください。",
              file=sys.stderr)
        return None


def run_agent(role_file, input_files, output_file, log_file=None,
              model_name="gemini-2.5-flash"):
    """
    Gemini エージェントを実行する。

    Args:
        role_file: システムプロンプト（役割定義）ファイルのパス
        input_files: 入力コンテキストファイルのパスリスト
        output_file: 出力先ファイルのパス
        log_file: ストリーミングログファイルのパス（tmux表示用）
        model_name: 使用するGeminiモデル名

    Returns:
        bool: 成功したかどうか
    """
    # クライアント初期化（認証モード自動判定）
    client = create_client()
    if client is None:
        return False

    # システムプロンプトの読み込み
    system_instruction = read_file_safe(role_file)
    if not system_instruction:
        print(f"[Error] Role file is empty or missing: {role_file}",
              file=sys.stderr)
        return False

    # 入力コンテキストの構築
    context = build_context(input_files)
    if not context:
        msg = "[Skip] All input files are empty. Nothing to process."
        print(msg)
        if log_file:
            with open(log_file, "a", encoding="utf-8") as f:
                f.write(msg + "\n")
        return False

    # マスキング設定
    redact_values = get_redact_values()
    redact_replacement = os.environ.get("REDACT_REPLACEMENT", "[REDACTED]")

    # ログファイルのオープン
    log_fh = None
    if log_file:
        try:
            log_fh = open(log_file, "a", encoding="utf-8")
        except IOError as e:
            print(f"[Warning] Could not open log file: {e}", file=sys.stderr)

    # 生成設定
    config = types.GenerateContentConfig(
        system_instruction=system_instruction,
    )

    # リトライ付き生成
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            if attempt > 1:
                delay = RETRY_DELAY_BASE ** attempt
                msg = f"[Retry] Attempt {attempt}/{MAX_RETRIES} in {delay}s..."
                print(msg, flush=True)
                if log_fh:
                    log_fh.write(msg + "\n")
                    log_fh.flush()
                time.sleep(delay)

            # ストリーミング生成
            collected = []
            for chunk in client.models.generate_content_stream(
                model=model_name,
                contents=context,
                config=config,
            ):
                if chunk.text:
                    raw_text = chunk.text
                    collected.append(raw_text)

                    masked_text = redact_text(raw_text, redact_values, redact_replacement)
                    # stdout にストリーミング出力
                    print(masked_text, end="", flush=True)
                    # ログにもストリーミング出力
                    if log_fh:
                        log_fh.write(masked_text)
                        log_fh.flush()

            # 最終改行
            print(flush=True)
            if log_fh:
                log_fh.write("\n")
                log_fh.flush()

            # 完全な出力を保存
            full_output = "".join(collected)
            if full_output.strip():
                with open(output_file, "w", encoding="utf-8") as f:
                    f.write(full_output)
                return True
            else:
                print("[Warning] Empty response from model.", file=sys.stderr)
                if attempt == MAX_RETRIES:
                    return False

        except Exception as e:
            error_msg = f"[Error] Attempt {attempt}/{MAX_RETRIES}: {str(e)}"
            print(error_msg, file=sys.stderr)
            if log_fh:
                log_fh.write(error_msg + "\n")
                log_fh.flush()
            if attempt == MAX_RETRIES:
                print("[Error] All retries exhausted.", file=sys.stderr)
                return False

    return False


def main():
    setup_signal_handlers()

    parser = argparse.ArgumentParser(
        description="Gemini Agent Runner - Run Gemini with a specified role"
    )
    parser.add_argument(
        "--role", required=True,
        help="Path to the system prompt (role definition) file"
    )
    parser.add_argument(
        "--input", required=True, nargs="+",
        help="Path(s) to input context files (supports multiple for context accumulation)"
    )
    parser.add_argument(
        "--output", required=True,
        help="Path to save the generated output"
    )
    parser.add_argument(
        "--log", default=None,
        help="Path to log file for streaming output (for tmux display)"
    )
    parser.add_argument(
        "--model", default=None,
        help="Model name (default: GEMINI_MODEL env or gemini-2.5-flash)"
    )
    args = parser.parse_args()

    model = args.model or os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")

    success = run_agent(
        role_file=args.role,
        input_files=args.input,
        output_file=args.output,
        log_file=args.log,
        model_name=model,
    )
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
