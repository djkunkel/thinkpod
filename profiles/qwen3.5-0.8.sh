# profiles/qwen3.5-4b.sh — Qwen 3.5 4B (Q4_K_M + vision)
#
# A small, fast reasoning model with multimodal (vision) support.
# Architecture: qwen35 | Max context: 262144 | Reasoning: yes | Vision: yes

REPO="unsloth/Qwen3.5-0.8B-GGUF"
FILES=("Qwen3.5-0.8B-Q8_0.gguf" "mmproj-F16.gguf")

# Runtime defaults — native llama-server flags.
# Baked into the image; overridable at `podman run` time via -- args.
#
# --reasoning-budget-message: text injected just before the forced </think>
# when the budget is exhausted. Without this, the model often leaks partial
# thoughts into the visible response. Critical for Qwen 3.5 — empirically
# recovers most of the quality lost from hard budget cutoffs.
DEFAULTS=(
    --ctx-size 8192
    --n-predict 4096
    --n-gpu-layers 999
    --flash-attn on
    --temperature 1.0
    --top-k 20
    --top-p 0.95
    --presence-penalty 1.5
    --reasoning on
    --reasoning-budget 1024
    --reasoning-budget-message $'\n\nOkay, I need to stop thinking and give my response now.\n'
)
