# profiles/qwen3.5-9b.sh — Qwen3.5-9B (Q6_K + vision)
#
# Dense 9B reasoning model with multimodal (vision) support. Near-lossless
# Q6_K quantization at 7.46 GB leaves ample room for 100K+ context on 24 GB.
# Architecture: qwen35 | Max context: 262144 | Reasoning: yes | Vision: yes

REPO="unsloth/Qwen3.5-9B-GGUF"
FILES=("Qwen3.5-9B-Q6_K.gguf" "mmproj-F16.gguf")

# Runtime defaults — native llama-server flags.
# Baked into the image; overridable at `podman run` time via -- args.
# Sampling values from the Qwen3.5 model card (thinking mode, general tasks).
#
# --reasoning-budget-message: text injected just before the forced </think>
# when the budget is exhausted. Without this, the model often leaks partial
# thoughts into the visible response. Critical for Qwen 3.5 — empirically
# recovers most of the quality lost from hard budget cutoffs.
DEFAULTS=(
    --ctx-size 131072
    --n-predict 32768
    --n-gpu-layers 999
    --flash-attn on
    --temperature 1.0
    --top-k 20
    --top-p 0.95
    --presence-penalty 1.5
    --reasoning on
    --reasoning-budget 4096
    --reasoning-budget-message $'\n\nOkay, I need to stop thinking and give my response now.\n'
)
