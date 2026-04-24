# profiles/qwen3.6-35b-a3b.sh — Qwen 3.6 35B-A3B (UD-Q4_K_M + vision)
#
# MoE model: 35B total parameters, only 3B activated per token.
# Decode speed is comparable to a ~4B dense model despite 35B-level quality.
# Focused on agentic coding, improved thinking preservation, and vision.
# Architecture: qwen3_5_moe | Max context: 262144 | Reasoning: yes | Vision: yes

REPO="unsloth/Qwen3.6-35B-A3B-GGUF"
FILES=("Qwen3.6-35B-A3B-UD-Q4_K_M.gguf" "mmproj-F16.gguf")

# Runtime defaults — native llama-server flags.
# Baked into the image; overridable at `podman run` time via -- args.
#
# Context capped at 131072: native max is 262144 but 32GB VRAM leaves ~10GB
# for KV cache at UD-Q4_K_M; 131072 keeps that budget comfortable.
#
# Sampling params per official model card (thinking mode, general tasks):
#   temperature=1.0, top_p=0.95, top_k=20, presence_penalty=1.5
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
