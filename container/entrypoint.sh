#!/usr/bin/env bash
#
# Container entrypoint for llama-server. Mirrors the env var interface from
# serve.sh so the container is a drop-in replacement.
#
# All settings have defaults and can be overridden via environment variables
# or by passing extra flags after the container command.

set -euo pipefail

# ── Source build-time environment (e.g. HSA_OVERRIDE_GFX_VERSION) ────────────

if [[ -f /etc/environment ]]; then
    set -a
    # shellcheck source=/dev/null
    source /etc/environment
    set +a
fi

# ── Configuration ────────────────────────────────────────────────────────────

HF_MODEL="${HF_MODEL:-__DEFAULT_MODEL__}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
CTX_SIZE="${CTX_SIZE:-100000}"
N_PREDICT="${N_PREDICT:-32768}"
N_GPU_LAYERS="${N_GPU_LAYERS:-999}"

# Sampling
TEMP="${TEMP:-1.0}"
TOP_K="${TOP_K:-20}"
TOP_P="${TOP_P:-0.95}"
PRESENCE_PENALTY="${PRESENCE_PENALTY:-1.5}"

# Flash attention (default: on)
FLASH_ATTN="${FLASH_ATTN:-on}"

# Reasoning / thinking
REASONING="${REASONING:-on}"
REASONING_BUDGET="${REASONING_BUDGET:-4096}"
REASONING_BUDGET_MSG="${REASONING_BUDGET_MSG:-$(printf '\n\nOkay, I need to stop thinking and give my response now.\n')}"

# ── Build the command ────────────────────────────────────────────────────────

args=(
    -hf "$HF_MODEL"
    --offline
    --host "$HOST"
    --port "$PORT"
    -c "$CTX_SIZE"
    -n "$N_PREDICT"
    -ngl "$N_GPU_LAYERS"
    --flash-attn "$FLASH_ATTN"
    --temp "$TEMP"
    --top-k "$TOP_K"
    --top-p "$TOP_P"
    --presence-penalty "$PRESENCE_PENALTY"
    --reasoning "$REASONING"
    --reasoning-budget "$REASONING_BUDGET"
    --metrics
)

if [[ -n "$REASONING_BUDGET_MSG" ]]; then
    args+=(--reasoning-budget-message "$REASONING_BUDGET_MSG")
fi

# Append any extra flags passed to the container
if [[ $# -gt 0 ]]; then
    args+=("$@")
fi

# ── Run ──────────────────────────────────────────────────────────────────────

echo "Model:      $HF_MODEL"
echo "Endpoint:   http://localhost:${PORT}"
echo "Flash-Attn: $FLASH_ATTN"
echo "Reasoning:  $REASONING (budget: $REASONING_BUDGET tokens)"
if [[ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]]; then
    echo "HSA GFX:    $HSA_OVERRIDE_GFX_VERSION"
fi
echo ""

# The upstream llama.cpp image places the binary at /app/llama-server.
# Try the PATH first, fall back to /app/llama-server.
if command -v llama-server &>/dev/null; then
    exec llama-server "${args[@]}"
else
    exec /app/llama-server "${args[@]}"
fi
