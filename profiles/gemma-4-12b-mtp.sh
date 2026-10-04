# profiles/gemma-4-12b-mtp.sh — Gemma 4 12B Unified (UD-Q4_K_XL + MTP + vision)
#
# Google DeepMind's Gemma 4 12B Unified model with Multi-Token Prediction (MTP)
# speculative decoding for ~1.5-2.2x faster inference. Encoder-free multimodal
# architecture with native text, image, and audio support. Hybrid reasoning model
# with configurable thinking mode. MTP drafter is a lightweight 465 MB GGUF in
# the same repo as the main weights.
# Architecture: gemma4 | Max context: 262144 | Reasoning: yes | Vision: yes
#
# Note: MTP + vision (--mmproj) may not work together depending on your llama.cpp
# build. If you encounter errors, disable vision with `-- --no-mmproj` or drop
# the MTP flags.

REPO="unsloth/gemma-4-12b-it-GGUF"
FILES=("gemma-4-12b-it-UD-Q4_K_XL.gguf")

# Runtime defaults — native llama-server flags.
# Passed directly to llama-server; overridable at run time via -- args.
#
# Sampling params per Google DeepMind / Unsloth docs:
#   temperature=1.0, top_p=0.95, top_k=64
# Presence/repetition penalty left at 0.0 per model card recommendation.
#
# Thinking mode: enabled by placing <|think|> at the start of the system
# prompt. To disable at run time: -- --chat-template-kwargs '{"enable_thinking":false}'
#
# MTP: --spec-type draft-mtp activates multi-token prediction speculative
# decoding. llama.cpp auto-downloads the repo's MTP head
# (mtp-gemma-4-12b-it.gguf, ~465 MB) and uses it as the drafter.
# --spec-draft-n-max 2 is the Unsloth-recommended starting point; try 1-6 and
# pick the fastest for your hardware. Plan ~2 GB RAM/VRAM headroom.
DEFAULTS=(
    --n-predict 32768
    --n-gpu-layers 999
    --flash-attn on
    --temperature 1.0
    --top-k 64
    --top-p 0.95
    --presence-penalty 0.0
    --reasoning on
    --spec-type draft-mtp
    --spec-draft-n-max 2
    --jinja
)
