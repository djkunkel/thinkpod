#!/usr/bin/env bash
#
# Build a self-contained llama-server container image with models baked in.
#
# Usage:
#   ./build.sh                     # build with default CUDA base + staged models
#   ./build.sh --rocm              # build with ROCm base (AMD discrete GPUs)
#   ./build.sh --gfx1103           # build ROCm with Radeon 780M/760M workaround
#   ./build.sh --vulkan            # build with Vulkan base (AMD iGPU/Intel/broad compat)
#   ./build.sh --tag my-llama:v1   # custom image tag
#   ./build.sh --skip-stage        # skip auto-staging (models/ must be populated)
#   ./build.sh --engine docker     # use docker instead of podman
#   ./build.sh --push              # build and push to container registry
#   ./build.sh --push --registry tendi.lan:4200/djkunkel  # explicit registry
#
# Prerequisites:
#   - Models staged in container/models/ (run models.sh first, or let this
#     script auto-stage the default model)
#   - podman or docker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/models"
MANIFEST="$MODELS_DIR/MANIFEST"

# ── Defaults ─────────────────────────────────────────────────────────────────

BASE_IMAGE_CUDA="ghcr.io/ggml-org/llama.cpp:server-cuda13"
BASE_IMAGE_ROCM="ghcr.io/ggml-org/llama.cpp:server-rocm"
BASE_IMAGE_VULKAN="ghcr.io/ggml-org/llama.cpp:server-vulkan"
BASE_IMAGE=""
GPU_BACKEND="cuda"
GFX1103_HACK=false
IMAGE_TAG=""
SKIP_STAGE=false
ENGINE=""
PUSH=false
REGISTRY="tendi.lan:4200/djkunkel"

# ── Parse args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rocm)       GPU_BACKEND="rocm"; shift ;;
        --cuda)       GPU_BACKEND="cuda"; shift ;;
        --vulkan)     GPU_BACKEND="vulkan"; shift ;;
        --gfx1103)    GPU_BACKEND="rocm"; GFX1103_HACK=true; shift ;;
        --tag)        IMAGE_TAG="$2"; shift 2 ;;
        --skip-stage) SKIP_STAGE=true; shift ;;
        --engine)     ENGINE="$2"; shift 2 ;;
        --base-image) BASE_IMAGE="$2"; shift 2 ;;
        --push)       PUSH=true; shift ;;
        --registry)   REGISTRY="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./build.sh [OPTIONS]"
            echo ""
            echo "Build a self-contained llama-server container image."
            echo ""
            echo "Options:"
            echo "  --cuda          Use CUDA base image (default, NVIDIA GPUs)"
            echo "  --rocm          Use ROCm base image (AMD discrete GPUs)"
            echo "  --gfx1103       ROCm with Radeon 780M/760M workaround (gfx1102 symlinks)"
            echo "  --vulkan        Use Vulkan base image (AMD iGPU, Intel, broad compat)"
            echo "  --base-image X  Override the base image entirely"
            echo "  --tag TAG       Custom image tag (default: auto-generated)"
            echo "  --skip-stage    Don't auto-stage models (models/ must exist)"
            echo "  --engine CMD    Container engine: podman or docker (auto-detected)"
            echo "  --push          Push image to container registry after building"
            echo "  --registry URL  Registry prefix (default: tendi.lan:4200/djkunkel)"
            echo "  --help          Show this help"
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            echo "Run ./build.sh --help for usage" >&2
            exit 1
            ;;
    esac
done

# ── Detect container engine ──────────────────────────────────────────────────

if [[ -z "$ENGINE" ]]; then
    if command -v podman &>/dev/null; then
        ENGINE="podman"
    elif command -v docker &>/dev/null; then
        ENGINE="docker"
    else
        echo "error: neither podman nor docker found" >&2
        exit 1
    fi
fi

echo "==> engine: $ENGINE"

# ── Select base image ────────────────────────────────────────────────────────

if [[ -z "$BASE_IMAGE" ]]; then
    case "$GPU_BACKEND" in
        cuda)   BASE_IMAGE="$BASE_IMAGE_CUDA" ;;
        rocm)   BASE_IMAGE="$BASE_IMAGE_ROCM" ;;
        vulkan) BASE_IMAGE="$BASE_IMAGE_VULKAN" ;;
        *)      echo "error: unknown backend: $GPU_BACKEND" >&2; exit 1 ;;
    esac
fi

echo "==> base image: $BASE_IMAGE"
echo "==> GPU backend: $GPU_BACKEND"
if $GFX1103_HACK; then
    echo "==> gfx1103:    Radeon 780M/760M workaround enabled"
fi

# ── Auto-stage models if needed ──────────────────────────────────────────────

gguf_count=$(find "$MODELS_DIR" -maxdepth 1 -name '*.gguf' 2>/dev/null | wc -l)

if [[ "$gguf_count" -eq 0 ]] && ! $SKIP_STAGE; then
    echo "==> no models staged, running models.sh with defaults..."
    "$SCRIPT_DIR/models.sh"
    echo ""
elif [[ "$gguf_count" -eq 0 ]] && $SKIP_STAGE; then
    echo "error: no .gguf files in $MODELS_DIR" >&2
    echo "       Run ./models.sh first to stage model files" >&2
    exit 1
fi

# ── Read MANIFEST ────────────────────────────────────────────────────────────

if [[ ! -f "$MANIFEST" ]]; then
    echo "error: $MANIFEST not found" >&2
    echo "       Run ./models.sh first" >&2
    exit 1
fi

# Source the manifest (sets REPO, COMMIT, FILES)
REPO=""
COMMIT=""
FILES=""
while IFS='=' read -r key value; do
    # Skip comments and blank lines
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    case "$key" in
        REPO)   REPO="$value" ;;
        COMMIT) COMMIT="$value" ;;
        FILES)  FILES="$value" ;;
    esac
done < "$MANIFEST"

if [[ -z "$REPO" || -z "$COMMIT" ]]; then
    echo "error: MANIFEST is missing REPO or COMMIT" >&2
    exit 1
fi

echo "==> repo: $REPO"
echo "==> commit: ${COMMIT:0:12}..."
echo "==> files: $FILES"

# ── Compute build args ───────────────────────────────────────────────────────

# Convert repo name to HF cache directory name: org/name → models--org--name
HF_REPO_CACHE="models--${REPO//\//__}"
# HF uses -- not __
HF_REPO_CACHE="models--${REPO//\//--}"

echo "==> cache dir: $HF_REPO_CACHE"

# ── Generate image tag if not provided ───────────────────────────────────────

if [[ -z "$IMAGE_TAG" ]]; then
    # Extract a short name from the repo: unsloth/Qwen3.5-4B-GGUF → qwen3.5-4b
    local_name="${REPO##*/}"            # Qwen3.5-4B-GGUF
    local_name="${local_name%-GGUF}"    # Qwen3.5-4B
    local_name="${local_name,,}"        # qwen3.5-4b (lowercase)

    # Try to extract quantization from filenames
    quant=""
    for f in $FILES; do
        if [[ "$f" != *mmproj* && "$f" =~ [-_](Q[0-9A-Z_]+)\. ]]; then
            quant="${BASH_REMATCH[1],,}"  # q4_k_m
            break
        fi
    done

    # Determine the backend suffix for the tag
    tag_backend="$GPU_BACKEND"
    if $GFX1103_HACK; then
        tag_backend="gfx1103"
    fi

    if [[ -n "$quant" ]]; then
        IMAGE_TAG="llama-serve:${local_name}-${quant}-${tag_backend}"
    else
        IMAGE_TAG="llama-serve:${local_name}-${tag_backend}"
    fi
fi

echo "==> image tag: $IMAGE_TAG"
echo ""

# ── Build ────────────────────────────────────────────────────────────────────

# Translate GFX1103_HACK bool to build arg
GFX1103_ARG="0"
if $GFX1103_HACK; then
    GFX1103_ARG="1"
fi

echo "==> building image..."
$ENGINE build \
    -f "$SCRIPT_DIR/Containerfile" \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg "HF_REPO=$REPO" \
    --build-arg "HF_REPO_CACHE=$HF_REPO_CACHE" \
    --build-arg "COMMIT_HASH=$COMMIT" \
    --build-arg "GFX1103_HACK=$GFX1103_ARG" \
    -t "$IMAGE_TAG" \
    "$SCRIPT_DIR"

echo ""
echo "==> build complete: $IMAGE_TAG"
echo ""

# ── Push to registry (if requested) ──────────────────────────────────────────

if $PUSH; then
    # Extract just the image name and tag parts: llama-serve:tag
    IMAGE_NAME="${IMAGE_TAG%%:*}"
    TAG_PART="${IMAGE_TAG#*:}"
    REMOTE_TAG="$REGISTRY/$IMAGE_NAME:$TAG_PART"

    echo "==> tagging: $REMOTE_TAG"
    $ENGINE tag "$IMAGE_TAG" "$REMOTE_TAG"

    echo "==> pushing to $REGISTRY..."
    $ENGINE push "$REMOTE_TAG"

    echo ""
    echo "==> pushed: $REMOTE_TAG"
    echo ""
    echo "Pull with:"
    echo ""
    echo "  $ENGINE pull $REMOTE_TAG"
fi

# ── Print run command ────────────────────────────────────────────────────────

RUN_IMAGE="$IMAGE_TAG"
if $PUSH; then
    RUN_IMAGE="$REMOTE_TAG"
fi

# Helper: print device flags for the current backend
print_device_flags() {
    case "$GPU_BACKEND" in
        cuda)
            echo "      --device nvidia.com/gpu=all \\"
            ;;
        rocm)
            echo "      --device /dev/kfd --device /dev/dri \\"
            echo "      --security-opt seccomp=unconfined \\"
            ;;
        vulkan)
            echo "      --device /dev/dri \\"
            ;;
    esac
}

echo ""
echo "Run with:"
echo ""
echo "  $ENGINE run --rm -it \\"
echo "      --network host \\"
print_device_flags
echo "      $RUN_IMAGE"

echo ""
echo "Override settings with -e flags:"
echo ""
echo "  $ENGINE run --rm -it \\"
echo "      --network host \\"
print_device_flags
echo "      -e CTX_SIZE=48000 \\"
echo "      -e PORT=9090 \\"
echo "      $RUN_IMAGE"

if $GFX1103_HACK; then
    echo ""
    echo "Note: gfx1103 workaround is baked in (HSA_OVERRIDE_GFX_VERSION=11.0.2)."
    echo "If flash attention crashes, disable it with: -e FLASH_ATTN=off"
fi
