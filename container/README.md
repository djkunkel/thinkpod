# container/ -- Self-contained llama-server image

Build a Docker/Podman container image with GGUF models baked in. The resulting
image runs the same llama-server configuration as `serve.sh` but needs no host
mounts -- models are embedded in the image.

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

## Files

| File | Description |
|---|---|
| `models.sh` | Stage model files from HF cache or download from Hub |
| `build.sh` | Build the container image |
| `run-remote.sh` | Pull and run on a remote machine (interactive picker) |
| `Containerfile` | Image definition (used by build.sh) |
| `entrypoint.sh` | Runtime entrypoint (copied into the image) |
| `models/` | Staging directory for GGUF files (gitignored) |

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

All the same environment variables from `serve.sh` work:

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

## Running on a remote machine

`run-remote.sh` is a standalone script for pulling and running images on
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
./run-remote.sh

# List available images
./run-remote.sh --list

# Run a specific tag directly
./run-remote.sh qwen3.5-4b-q4_k_m-vulkan
```

The script queries the OCI registry for available tags, detects the GPU backend
from the tag name, and runs with the correct device flags automatically.

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
as it does with a bind-mounted HF cache in `serve.sh`. The `-hf` flag handles
automatic mmproj detection, quantization tag matching, and split shard assembly.

The entrypoint script mirrors `serve.sh`'s configuration interface, assembling
the same llama-server flags from environment variables.

## Differences from serve.sh

| Aspect | `serve.sh` | Container image |
|---|---|---|
| Models | Bind-mounted from host HF cache | Baked into image |
| SELinux | `--security-opt label=disable` | Not needed (no bind mount) |
| Network | Always downloads model metadata | `--offline` (fully air-gapped) |
| GPU setup | CDI passthrough via podman | Same, but set by the runner |
| Updates | `podman pull` for new llama.cpp | Rebuild image |
