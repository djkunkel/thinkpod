# profiles/qwen3.6-27b.sh — Qwen 3.6 27B (UD-Q4_K_XL + vision)
#
# Dense 27B flagship: top agentic-coding performance at its weight class.
# Hybrid reasoning model with thinking preservation and multimodal vision.
# Architecture: qwen35 | Max context: 262144 | Reasoning: yes | Vision: yes

REPO="unsloth/Qwen3.6-27B-GGUF"
FILES=("Qwen3.6-27B-UD-Q4_K_XL.gguf" "mmproj-F16.gguf")

# Runtime defaults — native llama-server flags.
# Baked into the image; overridable at `podman run` time via -- args.
#
# Context capped at 131072: native max is 262144 but 32GB VRAM leaves ~10GB
# for KV cache at UD-Q4_K_XL; 131072 keeps that budget comfortable.
#
# Sampling params per Unsloth docs (thinking mode, general tasks):
#   temperature=1.0, top_p=0.95, top_k=20, presence_penalty=1.5
# Official Qwen model card recommends presence_penalty=0.0 for thinking mode;
# use `-- --presence-penalty 0.0` at run time for exact-model-card behaviour.
DEFAULTS=(
    -c 150000
    --n-predict 32768
    --n-gpu-layers 999
    --flash-attn on
    --temperature 0.6
    --top-k 20
    --min_p 0.0
    --top-p 0.95
    --presence-penalty 0.0
    --reasoning on
)
