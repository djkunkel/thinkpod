# profiles/qwopus3.6-35b-a3b-v1.sh — Qwopus3.6-35B-A3B-v1 (Q4_K_M + vision)
#
# Reasoning-enhanced MoE finetune of Qwen3.6-35B-A3B by Jackrong.
# 35B total params, 3B active per token. Improved structured reasoning,
# code generation, and multimodal vision via LoRA SFT.
# Architecture: qwen3_5_moe | Max context: 262144 | Reasoning: yes | Vision: yes

REPO="Jackrong/Qwopus3.6-35B-A3B-v1-GGUF"
FILES=("Qwopus3.6-35B-A3B-v1-Q4_K_M.gguf" "mmproj.gguf")

# Runtime defaults — native llama-server flags.
# Baked into the image; overridable at `podman run` time via -- args.
#
# Context set to 65536 per evaluation setup (q8_0 KV cache, single slot,
# ~25GB VRAM resident on 32GB card with all layers offloaded).
#
# Sampling params per model card evaluation setup (agentic mode):
#   temperature=0.3, top_p=0.9, thinking on
# For HTML generation use: --temperature 0.75 --top-p 0.95
DEFAULTS=(
    --n-predict 32768
    --n-gpu-layers 999
    --flash-attn on
    --jinja
    --temperature 0.3
    --top-p 0.9
    --reasoning on
    --reasoning-budget 6000
    --reasoning-budget-message $'\n\nOkay, I need to stop thinking and give my response now.\n'
)
