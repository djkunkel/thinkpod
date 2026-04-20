#!/usr/bin/env bash
#
# Test that the llama-server can handle the configured context size.
#
# This sends a prompt that fills most of the context window, asks the model
# to repeat back key details, and verifies the response completes without
# error. It also reports VRAM usage via nvidia-smi.
#
# Usage:
#   ./test-context.sh              # test against localhost:8080
#   ./test-context.sh 9090         # test against localhost:9090
#   ./test-context.sh 8080 0.9     # fill 90% of context (default: 75%)

set -euo pipefail

PORT="${1:-8080}"
FILL_RATIO="${2:-0.75}"
BASE_URL="http://localhost:${PORT}"

# ── Preflight ────────────────────────────────────────────────────────────────

echo "=== Context Size Stress Test ==="
echo ""

# Check server is up
if ! curl -sf "$BASE_URL/health" > /dev/null 2>&1; then
    echo "error: server not responding at $BASE_URL/health" >&2
    echo "       start the server first with scripts/serve.sh" >&2
    exit 1
fi

# Get server config
props=$(curl -sf "$BASE_URL/props")
n_ctx=$(echo "$props" | jq -r '.default_generation_settings.n_ctx // .total_slots')
# Try to get n_ctx from props; the field location varies by version
if [[ "$n_ctx" == "null" || -z "$n_ctx" ]]; then
    # Fallback: try /slots endpoint (requires --slots flag)
    slots=$(curl -sf "$BASE_URL/slots" 2>/dev/null || echo "[]")
    n_ctx=$(echo "$slots" | jq -r '.[0].n_ctx // empty' 2>/dev/null || echo "")
fi
if [[ -z "$n_ctx" || "$n_ctx" == "null" ]]; then
    echo "warning: could not detect n_ctx from server, using 48000" >&2
    n_ctx=48000
fi

echo "Server context size: $n_ctx tokens"
echo "Fill ratio:          $FILL_RATIO"
echo ""

# ── VRAM baseline ────────────────────────────────────────────────────────────

echo "--- VRAM before test ---"
nvidia-smi --query-gpu=name,memory.used,memory.total,memory.free \
    --format=csv,noheader,nounits 2>/dev/null | \
    while IFS=, read -r name used total free; do
        printf "  %s: %s MiB used / %s MiB total (%s MiB free)\n" \
            "$(echo "$name" | xargs)" \
            "$(echo "$used" | xargs)" \
            "$(echo "$total" | xargs)" \
            "$(echo "$free" | xargs)"
    done
echo ""

# ── Build a long prompt ──────────────────────────────────────────────────────

# We want to fill FILL_RATIO of the context with prompt tokens.
# A rough estimate: 1 token ~= 4 characters for English text.
# We leave room for the response (the remaining 1-FILL_RATIO of context).
target_tokens=$(python3 -c "print(int($n_ctx * $FILL_RATIO))")
# English text averages ~4.3 chars per token for llama-family tokenizers
target_chars=$(python3 -c "print(int($target_tokens * 4.3))")

echo "Target: ~${target_tokens} prompt tokens (~${target_chars} chars)"
echo "Building prompt..."

# Generate the prompt and request JSON using Python to avoid bash string
# limits (ARG_MAX) with 100K+ character prompts.
tmp_request=$(mktemp)
tmp_response=$(mktemp)
trap 'rm -f "$tmp_request" "$tmp_response"' EXIT

python3 -c "
import json, sys

target_chars = int(sys.argv[1])
needle = 'THE SECRET CODE IS: PINEAPPLE-7492'
needle_pos = target_chars // 2
padding = 'This is padding text to fill the context window. The quick brown fox jumps over the lazy dog. Testing memory and attention across a very long context.'

lines = []
char_count = 0
needle_placed = False
line_num = 0
while char_count < target_chars:
    line_num += 1
    if not needle_placed and char_count >= needle_pos:
        line = f'Line {line_num}: IMPORTANT - {needle}. Remember this for later.'
        needle_placed = True
    else:
        line = f'Line {line_num}: {padding}'
    lines.append(line)
    char_count += len(line) + 1  # +1 for newline

filler = '\n'.join(lines)
prompt = (
    'You are given a very long document below. Read it carefully and find the '
    'secret code embedded in it. Reply with ONLY the secret code, nothing else.'
    '\n\n--- DOCUMENT START ---\n'
    + filler +
    '\n--- DOCUMENT END ---\n\n'
    'What is the secret code from the document above? Reply with only the code.'
)

request = {
    'model': 'test',
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': 128,
    'temperature': 0.0,
    'chat_template_kwargs': {'enable_thinking': False},
}

with open(sys.argv[2], 'w') as f:
    json.dump(request, f)

" "$target_chars" "$tmp_request"

prompt_chars=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    print(len(json.load(f)['messages'][0]['content']))
" "$tmp_request")

echo "Prompt size: ${prompt_chars} chars (estimated ~$((prompt_chars / 4)) tokens)"
echo ""

# ── Send the request ─────────────────────────────────────────────────────────

echo "Sending request (this may take a while)..."
echo ""

start_time=$(date +%s%N)

# Disable reasoning for this test — we just need a short factual extraction,
# and thinking tokens would eat into max_tokens producing empty content.
http_code=$(curl -sf -o "$tmp_response" -w "%{http_code}" \
    "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "@$tmp_request" 2>&1 || echo "$?")

end_time=$(date +%s%N)
elapsed_ms=$(( (end_time - start_time) / 1000000 ))

echo "--- Results ---"
echo ""

if [[ -f "$tmp_response" && -s "$tmp_response" ]]; then
    # Check for error in response
    error=$(jq -r '.error.message // empty' "$tmp_response" 2>/dev/null || echo "")
    if [[ -n "$error" ]]; then
        echo "FAIL: Server returned error"
        echo "  HTTP status: $http_code"
        echo "  Error: $error"
        echo ""
        jq . "$tmp_response" 2>/dev/null || cat "$tmp_response"
    else
        content=$(jq -r '.choices[0].message.content // "NO CONTENT"' "$tmp_response" 2>/dev/null)
        finish_reason=$(jq -r '.choices[0].finish_reason // "unknown"' "$tmp_response" 2>/dev/null)
        prompt_tokens=$(jq -r '.usage.prompt_tokens // "?"' "$tmp_response" 2>/dev/null)
        completion_tokens=$(jq -r '.usage.completion_tokens // "?"' "$tmp_response" 2>/dev/null)

        echo "HTTP status:      $http_code"
        echo "Finish reason:    $finish_reason"
        echo "Prompt tokens:    $prompt_tokens"
        echo "Completion tokens: $completion_tokens"
        echo "Time:             ${elapsed_ms}ms"
        echo ""
        echo "Response: $content"
        echo ""

        # Check if the model found the needle
        if echo "$content" | grep -qi "PINEAPPLE-7492"; then
            echo "PASS: Model found the needle in the haystack"
        else
            echo "WARN: Model did not return the expected secret code"
            echo "  (This tests context attention, not just VRAM. Small models"
            echo "   may struggle with needle-in-haystack at long contexts.)"
        fi

        # Context utilization
        if [[ "$prompt_tokens" != "?" ]]; then
            pct=$(python3 -c "print(f'{$prompt_tokens / $n_ctx * 100:.1f}')")
            echo ""
            echo "Context utilization: ${prompt_tokens} / ${n_ctx} tokens (${pct}%)"
        fi
    fi
else
    echo "FAIL: No response from server (HTTP status: $http_code)"
    echo "  This likely means the server ran out of VRAM and crashed,"
    echo "  or the request timed out."
fi

# ── VRAM after test ──────────────────────────────────────────────────────────

echo ""
echo "--- VRAM after test ---"
nvidia-smi --query-gpu=name,memory.used,memory.total,memory.free \
    --format=csv,noheader,nounits 2>/dev/null | \
    while IFS=, read -r name used total free; do
        printf "  %s: %s MiB used / %s MiB total (%s MiB free)\n" \
            "$(echo "$name" | xargs)" \
            "$(echo "$used" | xargs)" \
            "$(echo "$total" | xargs)" \
            "$(echo "$free" | xargs)"
    done
echo ""

# ── Suggestions ──────────────────────────────────────────────────────────────

echo "--- Tips ---"
echo "  - If the test failed with OOM, reduce CTX_SIZE in scripts/serve.sh"
echo "  - To fit more context in VRAM, add KV cache quantization:"
echo "      scripts/serve.sh <model> --cache-type-k q8_0 --cache-type-v q4_0"
echo "  - Run with a higher fill ratio to push harder:"
echo "      ./test-context.sh $PORT 0.95"
echo ""
