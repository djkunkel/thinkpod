# thinkpod

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
# 1. Build with a profile
./build.sh --profile qwen3.5-4b --cuda

# 2. Run it
podman run --rm -it \
    --network host \
    --device nvidia.com/gpu=all \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-cuda
```

The server is OpenAI API-compatible and works with Open WebUI, continue.dev,
or any client that speaks the `/v1/chat/completions` protocol.

## Files

| File | Description |
|---|---|
| `build.sh` | Build a container image with models baked in |
| `models.sh` | Stage model files from HF cache or download from Hub |
| `new-profile.sh` | Interactive profile generator (queries HF Hub) |
| `Containerfile` | Image definition (used by build.sh) |
| `entrypoint.sh` | Runtime entrypoint (copied into the image) |
| `profiles/` | Model profiles (repo, files, runtime defaults) |
| `models/` | Staging directory for GGUF files (gitignored) |
| `scripts/serve.sh` | Direct serving via bind-mounted HF cache (no build needed) |
| `scripts/test-context.sh` | Context window stress test (needle-in-haystack) |
| `scripts/run-remote.sh` | Pull and run images from a registry on remote machines |

## Model profiles

Profiles define which model to build and its runtime defaults. Each profile is
a shell file in `profiles/` containing the HF repo, file list, and default
llama-server flags. See `profiles/README.md` for a detailed reference of all
available flags.

### Creating a profile

Use the interactive generator -- it queries HuggingFace for available
quantizations, detects vision/reasoning support, and writes the profile:

```sh
./new-profile.sh unsloth/Qwen3.5-4B-GGUF
```

It walks you through:
- Picking a quantization (recommends Q4_K_M)
- Including vision projector files (auto-detected)
- Setting context size (caps at a reasonable default)
- Enabling reasoning (auto-detected from chat template)

### Profile format

```sh
# profiles/qwen3.5-4b.sh
REPO="unsloth/Qwen3.5-4B-GGUF"
FILES=("Qwen3.5-4B-Q4_K_M.gguf" "mmproj-F16.gguf")

DEFAULTS=(
    --ctx-size 131072
    --n-predict 32768
    --n-gpu-layers 999
    --flash-attn on
    --reasoning on
    --reasoning-budget 4096
)
```

The `DEFAULTS` array contains native llama-server flags that get baked into the
image. They can be overridden at runtime (see [Runtime overrides](#runtime-overrides)).

### Listing available profiles

```sh
ls profiles/*.sh
```

## Staging models

`models.sh` populates `models/` with GGUF files for the build. It looks in the
host's HuggingFace cache first and falls back to downloading via the `hf` CLI.

```sh
# Stage using a profile
./models.sh --profile qwen3.5-4b

# Manual: specific repo and files
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

For models with vision support (like Qwen3.5), include the mmproj file
when staging. Profiles handle this automatically. For manual staging:

```sh
./models.sh unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-Q4_K_M.gguf mmproj-F16.gguf
```

llama-server's `-hf` flag auto-detects mmproj files by filename, so vision
works out of the box -- no extra configuration needed at runtime.

## Building

A GPU backend flag is **required** -- there is no default:

```sh
# With a profile (recommended)
./build.sh --profile qwen3.5-4b --cuda
./build.sh --profile qwen3.5-4b --rocm
./build.sh --profile qwen3.5-4b --vulkan

# Without a profile (uses whatever is in models/)
./build.sh --cuda

# Build and push to registry
./build.sh --profile qwen3.5-4b --cuda --push

# Custom tag
./build.sh --profile qwen3.5-4b --cuda --tag my-model:latest

# Use docker instead of podman
./build.sh --profile qwen3.5-4b --cuda --engine docker

# Custom base image (backend flag not needed)
./build.sh --base-image ghcr.io/ggml-org/llama.cpp:server-cuda13-b9000
```

The build produces a single image per invocation. Each backend uses a different
base image but the same model files. Run `build.sh` once per backend you need.

### Backend selection guide

| GPU | Backend | Flag |
|---|---|---|
| NVIDIA (any) | CUDA | `--cuda` |
| AMD discrete (RX 7000+, R9700) | ROCm | `--rocm` |
| AMD iGPU / Intel / broad compatibility | Vulkan | `--vulkan` |

## Running

### NVIDIA CUDA

```sh
podman run --rm -it \
    --network host \
    --device nvidia.com/gpu=all \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-cuda
```

### AMD ROCm (discrete)

```sh
podman run --rm -it \
    --network host \
    --device /dev/kfd --device /dev/dri \
    --security-opt seccomp=unconfined \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-rocm
```

### Vulkan

```sh
podman run --rm -it \
    --network host \
    --device /dev/dri \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-vulkan
```

### With docker

```sh
docker run --rm -it \
    --network host \
    --gpus all \
    llama-serve:qwen3.5-4b-cuda
```

### Sharing images without a registry

Images can be exported to a compressed tarball and loaded on another machine.
The format is compatible between podman and docker in both directions.

```sh
# Export
podman save localhost/llama-serve:qwen3.5-9b-cuda | gzip > qwen3.5-9b-cuda.tar.gz

# Load (podman or docker)
podman load -i qwen3.5-9b-cuda.tar.gz
docker load -i qwen3.5-9b-cuda.tar.gz
```

### Runtime overrides

Each image has runtime defaults baked in from the profile (context size,
reasoning, sampling params, etc.). Override any of them by passing native
llama-server flags after `--`:

```sh
# Override context size
podman run --rm -it \
    --network host \
    --device nvidia.com/gpu=all \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-cuda -- --ctx-size 8192

# Disable reasoning
podman run --rm -it \
    --network host \
    --device nvidia.com/gpu=all \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-cuda -- --reasoning off

# Multiple overrides
podman run --rm -it \
    --network host \
    --device nvidia.com/gpu=all \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-cuda -- --ctx-size 8192 --reasoning off --temperature 0.7

# Add extra llama-server flags not in the profile
podman run --rm -it \
    --network host \
    --device nvidia.com/gpu=all \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-cuda -- --cache-type-k q8_0 --cache-type-v q4_0
```

The entrypoint does **smart merging**: if you pass a flag that conflicts with
a default, only your version is used (no duplicate flags). Flags you don't
override keep their profile defaults.

### Infrastructure flags (always set)

These are hardcoded in the entrypoint and not part of the profile:

| Flag | Value | Why |
|---|---|---|
| `-hf` | *(baked-in repo)* | Model identity |
| `--offline` | | No network access needed |
| `--host` | `0.0.0.0` | Required inside containers |
| `--port` | `8080` | Standard port |
| `--metrics` | | Prometheus endpoint |

## Swapping models

Create a new profile and build:

```sh
# 1. Create a profile (interactive -- picks quant, detects vision/reasoning)
./new-profile.sh ggml-org/gemma-3-1b-it-GGUF

# 2. Build with the new profile
./build.sh --profile gemma-3-1b-it --cuda
```

Or manually:

```sh
# 1. Clean old staged files
./models.sh --clean

# 2. Stage the new model
./models.sh ggml-org/gemma-3-1b-it-GGUF

# 3. Rebuild
./build.sh --cuda
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
scripts/run-remote.sh qwen3.5-4b-vulkan
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

The entrypoint reads runtime defaults from `/defaults.conf` (baked in from the
model profile at build time) and merges them with any flags passed at `podman
run` time. User-supplied flags override profile defaults cleanly -- no
duplicate flags, no environment variables needed.

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

# Test a remote host
scripts/test-context.sh cowboy.lan:8080 0.75
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

The `--reasoning-budget-message` flag injects a nudge just before the forced
cutoff, which is critical for Qwen 3.5 -- without it, the model leaks partial
thoughts into the visible response and quality drops significantly.

Override reasoning settings at runtime via `--` flags:

```sh
# Larger budget
podman run --rm -it --network host --device nvidia.com/gpu=all \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-cuda -- --reasoning-budget 8192

# Unlimited thinking (no budget)
podman run --rm -it --network host --device nvidia.com/gpu=all \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-cuda -- --reasoning-budget -1

# Disable thinking entirely
podman run --rm -it --network host --device nvidia.com/gpu=all \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-cuda -- --reasoning off

# Custom budget message (nudge before forced cutoff)
podman run --rm -it --network host --device nvidia.com/gpu=all \
    --security-opt label=disable \
    llama-serve:qwen3.5-4b-cuda -- \
    --reasoning-budget-message "Let me summarize and respond."
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

SELinux blocks GPU device access inside containers even when the device node
is passed through. This applies to CUDA, ROCm, and Vulkan backends. The CDI
device flag alone is not sufficient on SELinux-enforcing hosts (Fedora/Bazzite).

## License

MIT License. See [LICENSE](LICENSE) for details.
