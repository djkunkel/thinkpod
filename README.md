# llama-serve

Build self-contained [llama.cpp](https://github.com/ggml-org/llama.cpp)
container images with GGUF models baked in. Supports NVIDIA CUDA, AMD ROCm,
and Vulkan GPU backends. No host mounts needed at runtime.

## Prerequisites

- **podman** or **docker**
- **`hf` CLI** for downloading models (`pip install huggingface_hub[cli]` or `brew install hf`)
- **NVIDIA GPU** with CUDA drivers and [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
  (CDI configured), **or** AMD GPU with ROCm/Vulkan drivers

### Verify CDI is working (NVIDIA)

```sh
podman run --rm --device nvidia.com/gpu=all ubuntu nvidia-smi
```

## Quick start

```sh
# 1. Stage models (copies from HF cache, or downloads if not cached)
./models.sh

# 2. Build the image
./build.sh

# 3. Run it
podman run --rm -it \
    --network host \
    --device nvidia.com/gpu=all \
    llama-serve:qwen3.5-4b-q4_k_m-cuda
```

The server is OpenAI API-compatible and works with Open WebUI, continue.dev,
or any client that speaks the `/v1/chat/completions` protocol.

## Files

| File | Description |
|---|---|
| `build.sh` | Build a container image with models baked in |
| `models.sh` | Stage model files from HF cache or download from Hub |
| `Containerfile` | Image definition (used by build.sh) |
| `entrypoint.sh` | Runtime entrypoint (copied into the image) |
| `models/` | Staging directory for GGUF files (gitignored) |
| `scripts/serve.sh` | Direct serving via bind-mounted HF cache (no build needed) |
| `scripts/test-context.sh` | Context window stress test (needle-in-haystack) |
| `scripts/run-remote.sh` | Pull and run images from a Gitea registry on remote machines |

## Staging models

`models.sh` populates `models/` with GGUF files for the build. It looks in the
host's HuggingFace cache first and falls back to downloading via the `hf` CLI.

```sh
# Default model (Qwen3.5-4B Q4_K_M + mmproj for vision)
./models.sh

# Specific repo and files
./models.sh unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-Q4_K_M.gguf mmproj-F16.gguf

# Just the repo (auto-discovers all GGUFs)
./models.sh unsloth/Qwen3.5-4B-GGUF

# Force re-download from Hub
./models.sh --download unsloth/Qwen3.5-4B-GGUF

# List what's available in your HF cache
./models.sh --list

# Clean staged files
./models.sh --clean
```

### Multimodal / vision models

For models with vision support (like Qwen3.5-4B), include the mmproj file
when staging. The default model stages it automatically:

```sh
# Both files staged by default:
#   Qwen3.5-4B-Q4_K_M.gguf   (model weights)
#   mmproj-F16.gguf           (vision projector)
./models.sh
```

llama-server's `-hf` flag auto-detects mmproj files by filename, so vision
works out of the box -- no extra configuration needed at runtime.

## Building

```sh
# NVIDIA CUDA (default)
./build.sh

# AMD ROCm (discrete GPUs: RX 7000 series, R9700, etc.)
./build.sh --rocm

# Vulkan (broad compatibility: AMD iGPU, Intel, any Vulkan-capable GPU)
./build.sh --vulkan

# Build and push to Gitea registry
./build.sh --vulkan --push

# Custom tag
./build.sh --tag my-llama:latest

# Use docker instead of podman
./build.sh --engine docker

# Custom base image
./build.sh --base-image ghcr.io/ggml-org/llama.cpp:server-cuda13-b9000
```

The build produces a single image per invocation. Each backend uses a different
base image but the same model files. Run `build.sh` once per backend you need.

### Backend selection guide

| GPU | Backend | Flag |
|---|---|---|
| NVIDIA (any) | CUDA | `--cuda` (default) |
| AMD discrete (RX 7000+, R9700) | ROCm | `--rocm` |
| AMD iGPU / Intel / broad compatibility | Vulkan | `--vulkan` |

## Running

### NVIDIA CUDA

```sh
podman run --rm -it \
    --network host \
    --device nvidia.com/gpu=all \
    llama-serve:qwen3.5-4b-q4_k_m-cuda
```

### AMD ROCm (discrete)

```sh
podman run --rm -it \
    --network host \
    --device /dev/kfd --device /dev/dri \
    --security-opt seccomp=unconfined \
    llama-serve:qwen3.5-4b-q4_k_m-rocm
```

### Vulkan

```sh
podman run --rm -it \
    --network host \
    --device /dev/dri \
    llama-serve:qwen3.5-4b-q4_k_m-vulkan
```

### With docker

```sh
docker run --rm -it \
    --network host \
    --gpus all \
    llama-serve:qwen3.5-4b-q4_k_m-cuda
```

### Override settings at runtime

All settings can be overridden via environment variables:

```sh
podman run --rm -it \
    --network host \
    --device nvidia.com/gpu=all \
    -e CTX_SIZE=48000 \
    -e PORT=9090 \
    -e REASONING_BUDGET=8192 \
    llama-serve:qwen3.5-4b-q4_k_m-cuda
```

### Pass extra llama-server flags

```sh
podman run --rm -it \
    --network host \
    --device nvidia.com/gpu=all \
    llama-serve:qwen3.5-4b-q4_k_m-cuda \
    --cache-type-k q8_0 --cache-type-v q4_0
```

## Configuration

All settings have defaults and can be overridden via `-e` flags at runtime:

| Variable | Default | Description |
|---|---|---|
| `HF_MODEL` | *(baked-in repo)* | HuggingFace repo for `-hf` flag |
| `HOST` | `0.0.0.0` | Listen address |
| `PORT` | `8080` | Listen port |
| `CTX_SIZE` | `100000` | Context window size in tokens |
| `N_PREDICT` | `32768` | Max tokens to generate per request |
| `N_GPU_LAYERS` | `999` | Layers to offload to GPU (999 = all) |
| `FLASH_ATTN` | `on` | Flash attention: `on` or `off` |
| `TEMP` | `1.0` | Sampling temperature |
| `TOP_K` | `20` | Top-K sampling |
| `TOP_P` | `0.95` | Top-P (nucleus) sampling |
| `PRESENCE_PENALTY` | `1.5` | Presence penalty |
| `REASONING` | `on` | Reasoning mode: `on`, `off`, or `auto` |
| `REASONING_BUDGET` | `4096` | Max thinking tokens before forced cutoff |
| `REASONING_BUDGET_MSG` | *(graceful wrap-up)* | Message injected at budget cutoff |

## Swapping models

To build an image with a different model:

```sh
# 1. Clean old staged files
./models.sh --clean

# 2. Stage the new model
./models.sh ggml-org/gemma-3-1b-it-GGUF

# 3. Rebuild
./build.sh
```

Each image contains one model. This keeps images focused and avoids multi-GB
bloat from unused models.

## Running on a remote machine

`scripts/run-remote.sh` is a standalone script for pulling and running images on
machines that don't have the full build environment. Copy it to the remote
machine or curl it from your Gitea instance.

### First-time setup

```sh
# 1. Configure insecure registry (if Gitea is plain HTTP)
echo '[[registry]]
location = "tendi.lan:4200"
insecure = true' | sudo tee /etc/containers/registries.conf.d/tendi-gitea.conf

# 2. Login to the registry
podman login tendi.lan:4200
```

### Usage

```sh
# Interactive: shows a menu of available images
scripts/run-remote.sh

# List available images
scripts/run-remote.sh --list

# Run a specific tag directly
scripts/run-remote.sh qwen3.5-4b-q4_k_m-vulkan
```

The script queries the OCI registry for available tags, detects the GPU backend
from the tag name, and runs with the correct device flags automatically.

## How it works

The image replicates the standard HuggingFace hub cache directory structure:

```
/root/.cache/huggingface/hub/
└── models--org--name/
    ├── refs/main              (commit hash)
    └── snapshots/{hash}/
        ├── Model-Q4_K_M.gguf
        └── mmproj-F16.gguf   (if multimodal)
```

This allows `llama-server -hf org/name --offline` to resolve the model exactly
as it does with a bind-mounted HF cache. The `-hf` flag handles automatic
mmproj detection, quantization tag matching, and split shard assembly.

The entrypoint script assembles llama-server flags from environment variables,
mirroring the same configuration interface across all run methods.

## scripts/

Utility scripts that aren't part of the container build process.

### serve.sh

Runs the official `ghcr.io/ggml-org/llama.cpp:server-cuda13` container directly
with the host's HuggingFace cache mounted read-only. No build step needed -- useful
for quick local testing.

```sh
# Default model
scripts/serve.sh

# Explicit model repo
scripts/serve.sh unsloth/Qwen3.5-4B-GGUF

# Override via environment variables
HF_MODEL=unsloth/Qwen3.5-4B-GGUF PORT=9090 scripts/serve.sh
```

### test-context.sh

Stress test that verifies your GPU has enough VRAM for the configured context
size. Sends a needle-in-haystack prompt that fills a configurable percentage
of the context window, then checks that the model can find a hidden code
phrase buried in the middle.

```sh
# Start the server first
scripts/serve.sh &

# Default: fill 75% of context
scripts/test-context.sh

# Fill 95% of context (aggressive test)
scripts/test-context.sh 8080 0.95
```

Reports VRAM usage before and after, actual token count, context utilization
percentage, and whether the model found the needle.

## Reasoning / thinking

Qwen3.5 is a thinking model that generates a `<think>...</think>` block before
responding. llama-server extracts this into `reasoning_content` in the API
response (separate from `content`), compatible with the OpenAI reasoning API.

### Budget control

The `--reasoning-budget` flag sets a hard token limit on thinking. When
exceeded, the server forcibly injects `</think>` to end the thinking phase.

**Without a budget message**, this abrupt cutoff often causes the model to leak
partial thoughts and raw `</think>` tags into the visible response.

**The fix**: `--reasoning-budget-message` injects a natural-language nudge just
before the forced `</think>`, giving the model a cue to wrap up cleanly:

```
\n\nOkay, I need to stop thinking and give my response now.\n
```

This is set by default. You can customize it at runtime:

```sh
# Custom message
podman run --rm -it --network host --device nvidia.com/gpu=all \
    -e REASONING_BUDGET_MSG="Let me summarize and respond." \
    llama-serve:qwen3.5-4b-q4_k_m-cuda

# Unlimited thinking (no budget)
podman run --rm -it --network host --device nvidia.com/gpu=all \
    -e REASONING_BUDGET=-1 \
    llama-serve:qwen3.5-4b-q4_k_m-cuda

# Disable thinking entirely
podman run --rm -it --network host --device nvidia.com/gpu=all \
    -e REASONING=off \
    llama-serve:qwen3.5-4b-q4_k_m-cuda
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
