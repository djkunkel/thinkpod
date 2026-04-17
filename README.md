# llama-serve

Serve GGUF models locally with full NVIDIA CUDA GPU acceleration using the
official [llama.cpp](https://github.com/ggml-org/llama.cpp) container image
and podman. No build step, no ramalama, no distrobox.

## Prerequisites

- **NVIDIA GPU** with CUDA drivers installed
- **podman** with [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
  and CDI configured (`/etc/cdi/nvidia.yaml`)
- **`hf` CLI** for downloading models (`pip install huggingface_hub[cli]` or `brew install hf`)
- **jq**, **curl**, **python3** (for the test script)

### Verify CDI is working

```sh
podman run --rm --device nvidia.com/gpu=all ubuntu nvidia-smi
```

## Quick start

```sh
# 1. Download a model to the standard HuggingFace cache
hf download unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-Q4_K_M.gguf mmproj-F16.gguf

# 2. Start the server
./serve.sh

# 3. Test it
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"test","messages":[{"role":"user","content":"Hello!"}]}'
```

The server is OpenAI API-compatible and works with Open WebUI, continue.dev,
or any client that speaks the `/v1/chat/completions` protocol.

## Files

| File | Description |
|---|---|
| `serve.sh` | Main serve script -- runs llama-server in a podman container |
| `test-context.sh` | Stress test -- verifies VRAM fits the configured context size |
| `serve-qwen.sh` | Old ramalama-based script (kept for reference) |

## serve.sh

Runs the official `ghcr.io/ggml-org/llama.cpp:server-cuda13` container with:

- HuggingFace cache mounted read-only (via `-hf` flag for model resolution)
- Host networking (bypasses podman pasta IPv6 bug)
- CDI GPU passthrough (`--device nvidia.com/gpu=all`)
- SELinux handled via `--security-opt label=disable`
- Flash attention enabled
- Reasoning/thinking budget with graceful termination message
- Vision/mmproj auto-detection (via `-hf`)
- Prometheus metrics at `/metrics`
- `--offline` to prevent container network access (models are pre-downloaded)

### Usage

```sh
# Default model (unsloth/Qwen3.5-4B-GGUF)
./serve.sh

# Explicit model repo
./serve.sh unsloth/Qwen3.5-4B-GGUF

# Specific quantization
./serve.sh unsloth/Qwen3.5-4B-GGUF:Q8_0

# Override via environment variables
HF_MODEL=unsloth/Qwen3.5-4B-GGUF PORT=9090 ./serve.sh

# Pass extra llama-server flags after the model argument
./serve.sh unsloth/Qwen3.5-4B-GGUF --cache-type-k q8_0 --cache-type-v q4_0
```

### Configuration

All settings have defaults and can be overridden via environment variables:

| Variable | Default | Description |
|---|---|---|
| `HF_MODEL` | `unsloth/Qwen3.5-4B-GGUF` | HuggingFace repo (or first positional arg) |
| `HF_HUB` | `~/.cache/huggingface/hub` | Path to HF cache directory |
| `IMAGE` | `ghcr.io/ggml-org/llama.cpp:server-cuda13` | Container image |
| `HOST` | `0.0.0.0` | Listen address |
| `PORT` | `8080` | Listen port |
| `CTX_SIZE` | `48000` | Context window size in tokens |
| `N_PREDICT` | `8000` | Max tokens to generate per request |
| `N_GPU_LAYERS` | `999` | Layers to offload to GPU (999 = all) |
| `TEMP` | `1.0` | Sampling temperature |
| `TOP_K` | `20` | Top-K sampling |
| `TOP_P` | `0.95` | Top-P (nucleus) sampling |
| `PRESENCE_PENALTY` | `1.8` | Presence penalty |
| `REASONING` | `on` | Reasoning mode: `on`, `off`, or `auto` |
| `REASONING_BUDGET` | `2048` | Max thinking tokens before forced cutoff |
| `REASONING_BUDGET_MSG` | *(graceful wrap-up prompt)* | Message injected at budget cutoff |

### Downloading models

Models live in the standard HuggingFace cache (`~/.cache/huggingface/hub/`).
Download them with the `hf` CLI on the host:

```sh
# Text-only model
hf download unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-Q4_K_M.gguf

# Text + vision (mmproj is auto-detected by -hf)
hf download unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-Q4_K_M.gguf mmproj-F16.gguf

# List what's cached
hf scan-cache
```

The `-hf` flag in llama-server resolves models from the HF cache
automatically, including auto-detecting mmproj files for vision models. No
need to specify file paths -- just the repo name.

### Updating llama.cpp

The container image is pinned to `server-cuda13` (latest tag). To update:

```sh
podman pull ghcr.io/ggml-org/llama.cpp:server-cuda13
```

To pin to a specific release:

```sh
IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda13-b9000 ./serve.sh
```

Check available tags at:
https://github.com/ggml-org/llama.cpp/pkgs/container/llama.cpp

## test-context.sh

Stress test that verifies your GPU has enough VRAM for the configured context
size. It works by sending a needle-in-haystack prompt that fills a configurable
percentage of the context window, then checking that the model can find a
hidden code phrase buried in the middle.

### Usage

```sh
# Start the server first
./serve.sh &

# Default: fill 75% of context
./test-context.sh

# Custom port
./test-context.sh 9090

# Fill 95% of context (aggressive test)
./test-context.sh 8080 0.95
```

### What it reports

- VRAM usage before and after the test (via `nvidia-smi`)
- Actual prompt token count and context utilization percentage
- Whether the model found the needle (tests both VRAM and attention quality)
- Elapsed time

### Benchmark results (RTX 4070 12GB, Qwen3.5-4B Q4_K_M)

| Fill | Prompt tokens | Context % | Needle found | Time |
|------|--------------|-----------|-------------|------|
| 50%  | 23,781 | 49.4% | Yes | 3.9s |
| 75%  | 35,695 | 74.2% | Yes | 8.5s |
| 95%  | 45,352 | 94.2% | Yes | 8.4s |

All tests passed at 48K context on 12GB VRAM with no KV cache quantization.

### If you run out of VRAM

Options, from least to most impact:

1. **Reduce `CTX_SIZE`** in `serve.sh` -- the most direct fix
2. **Quantize the KV cache** -- significant VRAM savings with minimal quality loss:
   ```sh
   ./serve.sh unsloth/Qwen3.5-4B-GGUF --cache-type-k q8_0 --cache-type-v q4_0
   ```
3. **Use a smaller quantization** of the model (e.g., Q3_K_M instead of Q4_K_M)
4. **Offload fewer layers** to GPU with a lower `N_GPU_LAYERS` (remaining layers
   run on CPU)

## Reasoning / thinking

Qwen3.5 is a thinking model that generates a `<think>...</think>` block before
responding. llama-server extracts this into `reasoning_content` in the API
response (separate from `content`), compatible with the OpenAI reasoning API.

### Budget control

The `--reasoning-budget` flag sets a hard token limit on thinking. When
exceeded, the server forcibly injects `</think>` to end the thinking phase.

**Without a budget message**, this abrupt cutoff often causes the model to leak
partial thoughts (e.g., "Let's write.") and raw `</think>` tags into the
visible response. This is a known issue across llama.cpp, vLLM, and other
serving frameworks.

**The fix**: `--reasoning-budget-message` injects a natural-language nudge just
before the forced `</think>`, giving the model a cue to wrap up cleanly:

```
\n\nOkay, I need to stop thinking and give my response now.\n
```

This is set by default in `serve.sh`. You can customize it:

```sh
# Custom message
REASONING_BUDGET_MSG="Let me summarize and respond." ./serve.sh

# Disable the message (not recommended)
REASONING_BUDGET_MSG="" ./serve.sh

# Unlimited thinking (no budget)
REASONING_BUDGET=-1 ./serve.sh

# Disable thinking entirely
REASONING=off ./serve.sh
```

### Per-request control

Clients can disable thinking for individual requests:

```json
{
  "messages": [{"role": "user", "content": "What is 2+2?"}],
  "chat_template_kwargs": {"enable_thinking": false}
}
```

## Architecture decisions

### Why not ramalama?

ramalama wraps llama.cpp but adds its own model store, container management,
and abstraction layers. This setup uses the official llama.cpp container
directly, which means:

- Models live in the standard HuggingFace cache (shared with other tools)
- Direct access to all llama-server flags (no `--runtime-args` workaround)
- Container image comes straight from the llama.cpp project
- Easier to debug -- fewer layers between you and llama-server

### Why host networking?

Podman's rootless network backend (pasta) has a bug where it accepts IPv6 TCP
connections on wildcard sockets but immediately resets them. Since `localhost`
resolves to `::1` first on many Linux systems, `curl http://localhost:8080/`
fails with a connection reset. `--network host` bypasses pasta entirely --
llama-server binds directly to the host's network interfaces.

### Why `--security-opt label=disable`?

SELinux on Bazzite/Fedora blocks the container from reading bind-mounted host
files by default. The alternative is `:z` on the volume mount, but that
triggers a recursive relabel of the entire HF cache (potentially 30GB+), which
is very slow. `--security-opt label=disable` skips SELinux enforcement for the
container and is sufficient -- `--privileged` is not needed.

### Why `--offline`?

The container mounts the HF cache read-only. The `--offline` flag tells
llama-server not to attempt any network requests for model downloads,
since everything is already cached on the host.

## System info

This was developed and tested on:

- **OS**: Bazzite 43 (Fedora Kinoite-based immutable distro)
- **GPU**: NVIDIA RTX 4070 12GB
- **Driver**: CUDA 13.2 (595.58.03)
- **Container runtime**: podman 5.8.1
- **GPU toolkit**: nvidia-container-toolkit 1.18.1 (CDI)
- **llama.cpp**: b8808 (`ghcr.io/ggml-org/llama.cpp:server-cuda13`)
- **Model**: unsloth/Qwen3.5-4B-GGUF (Q4_K_M, 2.6GB + mmproj-F16 642MB)
- **Performance**: ~110 tok/s generation, ~627 tok/s prompt processing
