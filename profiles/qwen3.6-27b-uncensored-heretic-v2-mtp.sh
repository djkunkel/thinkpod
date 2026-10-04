# profiles/qwen3.6-27b-uncensored-heretic-v2-mtp.sh — Qwen 3.6 27B Uncensored Heretic v2 MTP (Q4_K_M, vision)
#
# Decensored Qwen3.6-27B via Heretic v1.3.0 with Magnitude-Preserving Orthogonal Ablation (MPOA).
# 94% fewer refusals vs original with near-zero KL divergence (0.0021). All 15 MTP heads preserved
# for ~1.4-2x speculative decoding speedup. Vision projector included.
# Architecture: qwen3_6 | Max context: 262144 | Reasoning: yes | Vision: yes

REPO="llmfan46/Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-GGUF"
FILES=("Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-Q4_K_M.gguf")
TEMPLATE="qwen-fixed-chat-template.jinja"

# Runtime defaults — native llama-server flags.
# Passed directly to llama-server; overridable at run time via -- args.
#
# Q4_K_M is ~15 GB, leaving ample headroom on 32 GB VRAM for KV cache and mmproj.
# No --ctx-size set: llama-server auto-fits to available VRAM. With a container
# backend (--cuda/--cuda12), pass `-- --ctx-size 110000` since the container
# cannot see host VRAM.
#
# Note: MTP + vision (--mmproj) may not work together depending on your llama.cpp
# build. If you encounter errors, disable vision with `-- --no-mmproj` or drop
# the MTP flags.
#
# Sampling params per Qwen3.6 docs (thinking mode, general tasks):
#   temperature=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=1.5
# For precise coding/WebDev use `-- --temperature 0.6 --presence-penalty 0.0`.
#
# MTP: --spec-type draft-mtp activates multi-token prediction speculative
# decoding. --spec-draft-n-max 2 is the recommended sweet spot.
DEFAULTS=(
    --n-predict 32768
    --n-gpu-layers 999
    --flash-attn on
    --temperature 1.0
    --top-k 20
    --min-p 0.0
    --top-p 0.95
    --presence-penalty 1.5
    --reasoning on
    --spec-type draft-mtp
    --spec-draft-n-max 2
    --jinja
)
