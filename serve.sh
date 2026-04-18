#!/usr/bin/env bash
#
# Serve a GGUF model from the HuggingFace cache using llama.cpp in a podman
# container with CUDA GPU acceleration.
#
# Prerequisites:
#   - podman with nvidia-container-toolkit (CDI) configured
#   - Models downloaded to the standard HF cache:
#       hf download unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-Q4_K_M.gguf mmproj-F16.gguf
#
# Usage:
#   ./serve.sh                                          # default model
#   ./serve.sh unsloth/Qwen3.5-4B-GGUF                 # explicit repo
#   ./serve.sh unsloth/Qwen3.5-4B-GGUF:Q8_0            # specific quant
#   HF_MODEL=unsloth/Qwen3.5-4B-GGUF PORT=9090 ./serve.sh

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
# All settings can be overridden via environment variables.

HF_MODEL="${HF_MODEL:-${1:-unsloth/Qwen3.5-4B-GGUF}}"
HF_HUB="${HF_HUB:-$HOME/.cache/huggingface/hub}"
IMAGE="${IMAGE:-ghcr.io/ggml-org/llama.cpp:server-cuda13}"

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

# Reasoning / thinking
# --reasoning on: passes enable_thinking=true to the Jinja template
# --reasoning-budget N: hard token limit on thinking; when exceeded, the server
#   forcibly injects the budget message + </think> to end reasoning.
# --reasoning-budget-message: text injected just before the forced </think> to
#   nudge the model into wrapping up cleanly instead of being cut off mid-sentence.
#   Without this, the model often leaks partial thoughts into the visible response.
REASONING="${REASONING:-on}"
REASONING_BUDGET="${REASONING_BUDGET:-4096}"
REASONING_BUDGET_MSG="${REASONING_BUDGET_MSG:-$(printf '\n\nOkay, I need to stop thinking and give my response now.\n')}"

# ── Preflight checks ────────────────────────────────────────────────────────

if [[ ! -d "$HF_HUB" ]]; then
    echo "error: HuggingFace cache not found at $HF_HUB" >&2
    echo "       Set HF_HUB to point to your cache, or run:" >&2
    echo "       hf download <repo> <file>" >&2
    exit 1
fi

# ── Build the command ────────────────────────────────────────────────────────

args=(
    -hf "$HF_MODEL"
    --offline
    --host "$HOST"
    --port "$PORT"
    -c "$CTX_SIZE"
    -n "$N_PREDICT"
    -ngl "$N_GPU_LAYERS"
    --flash-attn on
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

# Append any extra flags passed after the model argument
shift 2>/dev/null || true
if [[ $# -gt 0 ]]; then
    args+=("$@")
fi

# ── Run ──────────────────────────────────────────────────────────────────────

# Use host networking so llama-server binds directly to the host's network
# interfaces. This avoids podman's pasta network backend which has an IPv6 bug
# (accepts IPv6 TCP connections then resets them, breaking "localhost"), and
# means the server is directly accessible from localhost and the LAN with no
# port-forwarding layer.

echo "Model:     $HF_MODEL"
echo "Image:     $IMAGE"
echo "Endpoint:  http://localhost:${PORT}"
echo "Reasoning: $REASONING (budget: $REASONING_BUDGET tokens)"
echo ""

exec podman run --rm -it \
    --network host \
    --security-opt label=disable \
    --device nvidia.com/gpu=all \
    -v "$HF_HUB:/root/.cache/huggingface/hub:ro" \
    "$IMAGE" \
    "${args[@]}"
