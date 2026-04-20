# Profile Defaults Reference

Each profile sets a `DEFAULTS` array of llama-server flags that get baked into
the container image. Users can override any of them at runtime:

```sh
podman run ... $IMAGE -- -c 8192 --reasoning off
```

The entrypoint merges defaults with user flags — user flags always win.

## Infrastructure flags (always set by entrypoint, not in profiles)

| Flag | Value | Purpose |
|------|-------|---------|
| `-hf` | (from build) | HuggingFace model path inside the container |
| `--offline` | | Prevent network access at runtime |
| `--host` | `0.0.0.0` | Listen on all interfaces |
| `--port` | `8080` | Listening port |
| `--metrics` | | Enable Prometheus-compatible `/metrics` endpoint |

These cannot be overridden via profiles — they are hardcoded in `entrypoint.sh`.

---

## Context and generation

| Flag | Example | Description |
|------|---------|-------------|
| `-c`, `--ctx-size` | `-c 131072` | Maximum prompt context size in tokens. This is the total window for input + output combined. Set to 0 to use the model's trained maximum. Larger values use more VRAM for the KV cache. |
| `-n`, `--predict`, `--n-predict` | `-n 32768` | Maximum tokens to generate per completion. Caps how long a single response can be. `-1` = unlimited (default). `0` = evaluate prompt into cache but generate nothing. |
| `-ngl`, `--n-gpu-layers` | `-ngl 999` | Number of model layers to offload to GPU. `999` means "all layers" (any number >= total layers works). Set to `0` for CPU-only inference. Also accepts `auto` and `all`. |

## Performance

| Flag | Example | Description |
|------|---------|-------------|
| `--flash-attn`, `-fa` | `--flash-attn on` | Flash Attention — reduces VRAM usage for the KV cache and speeds up attention computation. Values: `on`, `off`, `auto`. Generally should be `on` unless the backend doesn't support it. |

## Sampling — temperature and token selection

These control how the model picks the next token. Different models have
different recommended values — always check the model card.

| Flag | Example | Description |
|------|---------|-------------|
| `--temp`, `--temperature` | `--temp 1.0` | Randomness of generation. `0.0` = greedy/deterministic. Higher = more creative/random. Typical range: 0.0-2.0. Default: 0.8. |
| `--top-k` | `--top-k 20` | Only consider the top K most probable tokens at each step. `0` = disabled (consider all). Lower values = more focused output. Default: 40. |
| `--top-p` | `--top-p 0.95` | Nucleus sampling — only consider tokens whose cumulative probability is within the top P. `1.0` = disabled. Works with top-k (both filters apply). Default: 0.95. |
| `--min-p` | `--min-p 0.025` | Discard tokens with probability less than min-p times the most likely token's probability. `0.0` = disabled. Good alternative to top-k for open-ended generation. Default: 0.05. |

## Repetition control

These prevent the model from getting stuck in loops or repeating phrases.
Use **one** strategy — mixing `--repeat-penalty` with `--presence-penalty` can
over-penalize.

| Flag | Example | Description |
|------|---------|-------------|
| `--repeat-penalty` | `--repeat-penalty 1.05` | Penalize tokens that appeared in the last N tokens (see `--repeat-last-n`). `1.0` = disabled. Values >1.0 discourage repetition. Good for creative/narrative models. Default: 1.0. |
| `--repeat-last-n` | `--repeat-last-n 64` | How far back to look for repeated tokens when applying `--repeat-penalty`. `0` = disabled, `-1` = entire context. Default: 64. |
| `--presence-penalty` | `--presence-penalty 1.5` | Penalize tokens that have appeared at all in the output so far, regardless of frequency. `0.0` = disabled. Encourages topic diversity. Used by Qwen 3.5 model card recommendations. Default: 0.0. |
| `--frequency-penalty` | `--frequency-penalty 0.0` | Like presence penalty but scales with how many times the token appeared. `0.0` = disabled. Default: 0.0. |

## Reasoning (thinking models)

For models that support chain-of-thought reasoning (Qwen 3.5, DeepSeek, etc.).

| Flag | Example | Description |
|------|---------|-------------|
| `--reasoning`, `-rea` | `--reasoning on` | Enable or disable the thinking/reasoning mode. Values: `on`, `off`, `auto`. `auto` detects from the chat template. Default: `auto`. |
| `--reasoning-budget` | `--reasoning-budget 4096` | Token budget for the thinking phase. `-1` = unlimited, `0` = no thinking, `N` = max N tokens of reasoning before forcing a response. Default: -1. |
| `--reasoning-budget-message` | (see below) | Text injected just before the `</think>` tag when the budget runs out. Critical for Qwen 3.5 — without it, the model leaks partial thoughts into the visible response and quality drops significantly. |

The `--reasoning-budget-message` value is a string, typically a newline-padded
sentence that tells the model to wrap up its thinking:

```
$'\n\nOkay, I need to stop thinking and give my response now.\n'
```

The `$'...'` quoting is required in the profile because the value contains
literal newlines that must survive serialization into `defaults.conf`.

## Flags NOT in profiles (but useful at runtime)

| Flag | Example | Description |
|------|---------|-------------|
| `-np`, `--parallel` | `-np 2` | Number of concurrent request slots. More slots = more simultaneous users but more VRAM. Default: auto. |
| `-ctk`, `--cache-type-k` | `-ctk q8_0` | KV cache quantization for keys. Lower precision = less VRAM but slight quality loss. Options: `f16`, `q8_0`, `q4_0`, etc. Default: `f16`. |
| `-ctv`, `--cache-type-v` | `-ctv q8_0` | Same as above but for values. |
| `--chat-template` | `--chat-template chatml` | Override the chat template. Usually auto-detected from the model. |
| `--api-key` | `--api-key mysecret` | Require an API key for all requests. |

## Full reference

The complete flag list is in the llama.cpp server documentation:
https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
