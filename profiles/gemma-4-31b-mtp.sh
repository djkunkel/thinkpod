# profiles/gemma-4-31b-mtp.sh — Gemma 4 31B (UD-Q4_K_XL + MTP + vision)
#
# Google DeepMind's strongest Gemma 4 dense model. Multimodal (text + image),
# hybrid reasoning with configurable thinking mode via <|think|> system token.
# MTP speculative decoding gives ~1.4x+ speedup on this dense model.
# Architecture: gemma4 | Max context: 262144 | Reasoning: yes | Vision: yes
#
# Note: MTP + vision (--mmproj) may not work together depending on your llama.cpp
# build. If you encounter errors, disable vision with `-- --no-mmproj` or drop
# the MTP flags.

REPO="unsloth/gemma-4-31B-it-GGUF"
FILES=("gemma-4-31B-it-UD-Q4_K_XL.gguf")

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
# (mtp-gemma-4-31B-it.gguf, ~515 MB) and uses it as the drafter.
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
