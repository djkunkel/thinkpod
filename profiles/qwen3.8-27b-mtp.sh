# profiles/qwen3.8-27b-mtp.sh — Qwen 3.8 27B MTP (UD-Q5_K_XL, vision)
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
# Vision: llama-server auto-downloads and loads the repo's projector
# (mmproj-BF16.gguf) via -hf. To disable vision: `-- --no-mmproj`.

REPO="unsloth/Qwen3.8-27B-GGUF"
FILES=("Qwen3.8-27B-UD-Q5_K_XL.gguf")
# TEMPLATE="qwen-fixed-chat-template.jinja"

# --- Template / steering research notes (2026-08-15) ---
# The GGUF's built-in template is Qwen's official tokenizer_config.json chat
# template, which DOES support the steering kwargs below — so the custom
# template is left commented out while we experiment with stock behavior.
#
# Built-in template steering support (verified against Qwen/Qwen3.8-27B):
#   reasoning_effort   xhigh (default) | medium | low  — injects a steering
#                      instruction into the system prompt. NOTE: only these
#                      three are accepted; "high"/"max"/"minimal" raise an
#                      exception (v22 of the custom template aliases high ->
#                      xhigh). llama.cpp's native --reasoning-effort forwards
#                      the value straight through, so the same restriction
#                      applies.
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
#   -- --reasoning-effort low|medium|xhigh   prefer over chat-template-kwargs:
#                        native flag, maps to the template's reasoning_effort
#   -- --chat-template-kwargs '{"enable_thinking":false}'   disable thinking
#   -- --chat-template-kwargs '{"preserve_thinking":false}' drop past <think>
# Also settable per-request via the OpenAI-compatible `chat_template_kwargs`
# request field. Other native flags:
#   --reasoning on|off  --reasoning-budget N
# NOTE: --reasoning-preserve maps to the generic `preserve_reasoning` kwarg,
# which Qwen3.8's template DOES NOT read — use `preserve_thinking` instead.

# Runtime defaults — native llama-server flags.
# Passed directly to llama-server; overridable at run time via -- args.
#
# UD-Q5_K_XL is ~20.9 GB. On 32 GB VRAM that leaves ~11 GB for KV cache, so
# context auto-fit still lands short of the 262144 native maximum. Drop to
# UD-Q4_K_XL (~17.6 GB) for longer context, or pass a fixed `-- --ctx-size N`
# on container backends (--cuda/--cuda12), which cannot see host VRAM.
# Trained max is 262144; extendable to ~1M via YaRN rope scaling.
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
# decoding. llama.cpp auto-downloads the repo's MTP head
# (MTP/mtp-Qwen3.8-27B-Q4_0.gguf, ~1.4 GB) and uses it as the drafter — no
# extra flag needed. --spec-draft-n-max 2 is the Unsloth-recommended starting
# point; performance is hardware-dependent, so try 1-6 and keep the fastest.
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
