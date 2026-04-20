# profiles/qwen3.5-4b.sh — Qwen 3.5 4B (Q4_K_M + vision)
#
# A small, fast reasoning model with multimodal (vision) support.
# Architecture: qwen35 | Max context: 262144 | Reasoning: yes | Vision: yes

REPO="unsloth/Qwen3.5-4B-GGUF"
FILES=("Qwen3.5-4B-Q4_K_M.gguf" "mmproj-F16.gguf")

# Runtime defaults — native llama-server flags.
# Baked into the image; overridable at `podman run` time via -- args.
DEFAULTS=(
    -c 131072
    -n 32768
    -ngl 999
    --flash-attn on
    --temp 1.0
    --top-k 20
    --top-p 0.95
    --presence-penalty 1.5
    --reasoning on
    --reasoning-budget 4096
)
