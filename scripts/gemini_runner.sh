#!/bin/bash
# ============================================================
# Gemini Agent Runner (CLI版)
# ============================================================
# gemini CLI (npm @google/gemini-cli) を使用してエージェントを実行する。
#
# 使い方:
#   bash gemini_runner.sh \
#     --role agents/analyst.md \
#     --input project/default/REQUEST.md \
#     --output project/default/REQUIREMENTS.md \
#     --log logs/analyst.log \
#     --model gemini-2.5-flash
# ============================================================

set -uo pipefail

# --- Signal Handlers ---
trap 'printf "\n[Agent] Interrupted. Exiting gracefully.\n" >&2; rm -f "${_tmpfile:-}" 2>/dev/null; exit 130' INT TERM

# --- Argument Parsing ---
_role_file=""
declare -a _input_files=()
_output_file=""
_log_file=""
_model=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            _role_file="$2"
            shift 2
            ;;
        --input)
            shift
            while [[ $# -gt 0 && "$1" != --* ]]; do
                _input_files+=("$1")
                shift
            done
            ;;
        --output)
            _output_file="$2"
            shift 2
            ;;
        --log)
            _log_file="$2"
            shift 2
            ;;
        --model)
            _model="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --role <file> --input <files...> --output <file> [--log <file>] [--model <name>]"
            exit 0
            ;;
        *)
            echo "[Error] Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

_model="${_model:-${GEMINI_MODEL:-gemini-2.5-flash}}"

# --- Validate Inputs ---
if [[ -z "$_role_file" || ! -f "$_role_file" || ! -s "$_role_file" ]]; then
    echo "[Error] Role file is empty or missing: ${_role_file:-<not specified>}" >&2
    exit 1
fi

if [[ -z "$_output_file" ]]; then
    echo "[Error] Output file not specified (--output)" >&2
    exit 1
fi

if [[ ${#_input_files[@]} -eq 0 ]]; then
    echo "[Error] No input files specified (--input)" >&2
    exit 1
fi

# --- Build Context ---
_has_context=false
for _f in "${_input_files[@]}"; do
    if [[ -f "$_f" && -s "$_f" ]]; then
        _has_context=true
        break
    fi
done

if ! $_has_context; then
    _msg="[Skip] All input files are empty. Nothing to process."
    echo "$_msg"
    [[ -n "$_log_file" ]] && echo "$_msg" >> "$_log_file"
    exit 1
fi

# --- Redaction Helper ---
_redact_in_file() {
    local target="$1"
    local replacement="${REDACT_REPLACEMENT:-[REDACTED]}"
    local raw="${REDACT_VALUES:-}"
    local api_key="${GEMINI_API_KEY:-}"

    [[ -z "$raw" && -z "$api_key" ]] && return 0
    [[ ! -f "$target" || ! -s "$target" ]] && return 0

    # Build list of values to redact
    local -a vals=()
    IFS=',' read -ra items <<< "$raw"
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"   # ltrim
        item="${item%"${item##*[![:space:]]}"}"   # rtrim
        [[ -n "$item" ]] && vals+=("$item")
    done
    if [[ -n "$api_key" ]]; then
        local found=false
        for v in "${vals[@]+"${vals[@]}"}"; do
            [[ "$v" == "$api_key" ]] && found=true
        done
        $found || vals+=("$api_key")
    fi

    [[ ${#vals[@]} -eq 0 ]] && return 0

    # Apply redaction using Python (handles special chars safely)
    python3 - "$target" "$replacement" "${vals[@]}" <<'PY' 2>/dev/null || true
import sys
path = sys.argv[1]
replacement = sys.argv[2]
values = sys.argv[3:]
with open(path, "r", encoding="utf-8", errors="ignore") as f:
    data = f.read()
for val in values:
    if val:
        data = data.replace(val, replacement)
with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY
}

# --- Constants ---
_MAX_RETRIES=3
_RETRY_DELAY_BASE=2

# --- Main Loop ---
for _attempt in $(seq 1 $_MAX_RETRIES); do
    if [[ $_attempt -gt 1 ]]; then
        _delay=$((_RETRY_DELAY_BASE ** _attempt))
        _msg="[Retry] Attempt ${_attempt}/${_MAX_RETRIES} in ${_delay}s..."
        echo "$_msg" >&2
        [[ -n "$_log_file" ]] && echo "$_msg" >> "$_log_file"
        sleep "$_delay"
    fi

    # Create temp file for capturing output
    _tmpfile=$(mktemp)

    # Initialize log file
    [[ -n "$_log_file" ]] && : >> "$_log_file"

    # Build prompt and call Gemini CLI
    # - System prompt (role file) is sent first
    # - Input context files follow after a separator
    # - gemini -o text returns plain text response
    {
        cat "$_role_file"
        echo ""
        echo "---"
        echo ""
        echo "以下の入力コンテキストに基づいて、上記のシステム指示に従い出力を生成してください。"
        echo ""
        for _f in "${_input_files[@]}"; do
            if [[ -f "$_f" && -s "$_f" ]]; then
                echo "=== $(basename "$_f") ==="
                cat "$_f"
                echo ""
            fi
        done
    } | gemini -m "$_model" -o text 2>/dev/null | \
        tee "$_tmpfile" | \
        tee -a "${_log_file:-/dev/null}" || true

    # Check if output is non-empty
    if [[ -s "$_tmpfile" ]]; then
        # Save to output file
        cp "$_tmpfile" "$_output_file"
        # Redact sensitive values in log
        [[ -n "$_log_file" ]] && _redact_in_file "$_log_file"
        rm -f "$_tmpfile"
        echo "" # trailing newline
        exit 0
    fi

    # Error
    _error_msg="[Error] Attempt ${_attempt}/${_MAX_RETRIES}: gemini CLI returned empty response"
    echo "$_error_msg" >&2
    [[ -n "$_log_file" ]] && echo "$_error_msg" >> "$_log_file"
    rm -f "$_tmpfile"

    if [[ $_attempt -eq $_MAX_RETRIES ]]; then
        echo "[Error] All retries exhausted." >&2
        exit 1
    fi
done

exit 1
