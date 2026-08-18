# profiles/qwen3.8-27b-mtp.sh — Qwen 3.8 27B MTP (UD-Q6_K_XL, vision)
#
# Dense 27B flagship with MTP (Multi-Token Prediction) support for fast
# speculative decoding. Hybrid reasoning model with thinking preservation,
# native vision-language understanding (image + video), and flexible thinking
# control via `reasoning_effort`. Top agentic-coding performance at its class.
# Architecture: qwen35 | Max context: 262144 | Reasoning: yes | Vision: yes
#
# Note: MTP + vision may not work together depending on your llama.cpp build.
# If you encounter errors, disable vision with `-- --no-mmproj` or drop the
# MTP flags.
#
# Vision: the mmproj* entry in FILES is advisory — run.sh ignores it and
# llama-server auto-downloads + loads the repo's default projector
# (mmproj-BF16.gguf) via -hf. To disable vision: `-- --no-mmproj`.

REPO="unsloth/Qwen3.8-27B-GGUF"
FILES=("Qwen3.8-27B-UD-Q5_K_XL.gguf" "mmproj-BF16.gguf")
# TEMPLATE="qwen-fixed-chat-template.jinja"

# --- Template / steering research notes (2026-08-15) ---
# The GGUF's built-in template is Qwen's official tokenizer_config.json chat
# template, which DOES support the steering kwargs below — so the custom
# template is left commented out while we experiment with stock behavior.
#
# Built-in template steering support (verified against Qwen/Qwen3.8-27B):
#   reasoning_effort   xhigh (default) | medium | low  — injects a steering
#                      instruction into the system prompt. NOTE: "high" is NOT
#                      accepted and raises an exception; v22 of the custom
#                      template aliases high -> xhigh.
#   enable_thinking    true (default) | false — fast non-reasoning mode.
#   preserve_thinking  true (default) | false — re-emit past <think> blocks.
#
# Known built-in template bugs (why the custom template exists — see
# templates/qwen-fixed-chat-template.jinja, upstream froggeric/Qwen-Fixed-
# Chat-Templates v22):
#   * Multi-turn "empty think" — reads reasoning only from the
#     `reasoning_content` field; no in-content <think> parser, so reasoning
#     stored inline yields blank <think></think> blocks.
#   * String tool args crash — `tool_call.arguments|items` throws on OpenAI
#     JSON-string arguments.
#   * Strict ordering — mid-conversation system messages and the
#     no-system-message + tools case raise exceptions.
#
# How to steer (both work without the custom template):
#   -- --chat-template-kwargs '{"reasoning_effort":"low"}'
#   -- --chat-template-kwargs '{"enable_thinking":false}'
#   -- --chat-template-kwargs '{"preserve_thinking":false}'
# Also settable per-request via the OpenAI-compatible `chat_template_kwargs`
# request field. Native llama-server flags (template-independent):
#   --reasoning on|off  --reasoning-budget N  --reasoning-preserve

# Runtime defaults — native llama-server flags.
# Passed directly to llama-server; overridable at run time via -- args.
#
# UD-Q6_K_XL is ~25.9 GB. On 32 GB VRAM that leaves only ~6 GB for KV cache,
# so context auto-fit lands well short of the 262144 native maximum. Drop to
# UD-Q4_K_XL if you need long context, or pass a fixed `-- --ctx-size N` on
# container backends (--cuda/--cuda12), which cannot see host VRAM.
#
# Sampling params per Unsloth Qwen3.8 docs (thinking mode, the default):
#   temperature=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=0.0
# Instruct (non-thinking) mode instead uses temperature=0.7, top_p=0.80,
# presence_penalty=1.5. Override at run time:
#   -- --temperature 0.7 --top-p 0.80 --presence-penalty 1.5
#
# Thinking control: `--reasoning on` is the default. Toggle thinking off or
# preserve prior reasoning traces via chat-template-kwargs, e.g.:
#   -- --chat-template-kwargs '{"enable_thinking":false,"preserve_thinking":true}'
#
# MTP: --spec-type draft-mtp activates multi-token prediction speculative
# decoding. --spec-draft-n-max 2 is the Unsloth-recommended sweet spot.
# (llama.cpp renamed --spec-type mtp → draft-mtp on 2026-05-13; requires a
# recent build or release binary.)
DEFAULTS=(
    --n-predict 32768
    --n-gpu-layers 999
    --flash-attn on
    --temperature 1.0
    --top-k 20
    --min-p 0.0
    --top-p 0.95
    --presence-penalty 0.0
    --reasoning on
    --spec-type draft-mtp
    --spec-draft-n-max 2
    --cache-type-v q8_0
    --jinja
)
