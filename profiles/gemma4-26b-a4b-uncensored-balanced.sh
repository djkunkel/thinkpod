# profiles/gemma4-26b-a4b-uncensored-balanced.sh — Gemma4 26B A4B Uncensored (Balanced) (Q5_K_P + vision)
#
# HauhauCS's uncensored "Balanced" release candidate of Google's Gemma4-26B-A4B.
# 25.2B total / 3.8B active MoE (top-8 of 128 experts + 1 shared), so you get
# a 26B reasoning footprint at ~4B inference cost. Natively multimodal text +
# vision with a hybrid attention (sliding-window 1024 → full global, p-RoPE).
# 0/465 refusals in standard use; full original capabilities retained.
# Architecture: gemma4 | Max context: 262144 | Reasoning: yes | Vision: yes

REPO="HauhauCS/Gemma4-26B-A4B-Uncensored-HauhauCS-Balanced"
FILES=("Gemma4-26B-A4B-Uncensored-HauhauCS-Balanced-Q5_K_P.gguf")

# Runtime defaults — native llama-server flags.
# Passed directly to llama-server; overridable at run time via -- args.
#
# Sampling params per Google DeepMind / HauhauCS model card:
#   temperature=1.0, top_p=0.95, top_k=64
# Presence/repetition penalty left at 0.0 per model card recommendation.
#
# Q5_K_P: HauhauCS custom "Perfect" quant — top ~25% tensors (by imatrix)
# promoted to a higher quant type. ~1-2 quant levels better quality than Q5_K_M
# at near-identical file size. Fully llama.cpp-compatible.
#
# Thinking mode: enabled via enable_thinking in the chat template (same pattern
# as Qwen3.6). To disable at run time:
#   -- --chat-template-kwargs '{"enable_thinking":false}'
DEFAULTS=(
    --n-predict 32768
    --n-gpu-layers 999
    --flash-attn on
    --temperature 1.0
    --top-k 64
    --top-p 0.95
    --presence-penalty 0.0
    --reasoning on
    --reasoning-budget 4096
    --reasoning-budget-message $'\n\nOkay, I need to stop thinking and give my response now.\n'
    --jinja
)
