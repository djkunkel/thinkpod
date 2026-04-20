#!/usr/bin/env bash
#
# Build a self-contained llama-server container image with models baked in.
#
# Usage:
#   ./build.sh --cuda                                # NVIDIA GPU, CUDA 13 (required: pick a backend)
#   ./build.sh --cuda12                              # NVIDIA GPU, CUDA 12
#   ./build.sh --rocm                                # AMD discrete GPU
#   ./build.sh --vulkan                              # Vulkan (AMD iGPU, Intel, broad compat)
#   ./build.sh --profile qwen3.5-4b --cuda           # use a model profile
#   ./build.sh --cuda --tag my-llama:v1              # custom image tag
#   ./build.sh --cuda --skip-stage                   # skip auto-staging
#   ./build.sh --cuda --push                         # build and push to registry
#   ./build.sh --cuda --push --registry host/org     # explicit registry
#
# Prerequisites:
#   - A GPU backend flag (--cuda, --cuda12, --rocm, or --vulkan)
#   - Models staged in models/ (run models.sh first, or let this script
#     auto-stage via --profile or defaults)
#   - podman or docker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/models"
MANIFEST="$MODELS_DIR/MANIFEST"
DEFAULTS_FILE="$SCRIPT_DIR/defaults.conf"

# Clean up generated defaults.conf on exit (success or failure)
cleanup() { rm -f "$DEFAULTS_FILE"; }
trap cleanup EXIT

# ── Defaults ─────────────────────────────────────────────────────────────────

BASE_IMAGE_CUDA="ghcr.io/ggml-org/llama.cpp:server-cuda13"
BASE_IMAGE_CUDA12="ghcr.io/ggml-org/llama.cpp:server-cuda"
BASE_IMAGE_ROCM="ghcr.io/ggml-org/llama.cpp:server-rocm"
BASE_IMAGE_VULKAN="ghcr.io/ggml-org/llama.cpp:server-vulkan"
BASE_IMAGE=""
GPU_BACKEND=""
IMAGE_TAG=""
SKIP_STAGE=false
ENGINE=""
PUSH=false
REGISTRY="tendi.lan:4200/djkunkel"
PROFILE=""

# Fallback runtime defaults (used when no profile is specified)
FALLBACK_DEFAULTS=(
    -c 131072
    -n 32768
    -ngl 999
    --flash-attn on
    --temp 1.0
    --top-k 20
    --top-p 0.95
    --presence-penalty 1.5
    --reasoning on
    --reasoning-budget 4096
)

# ── Parse args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rocm)       GPU_BACKEND="rocm"; shift ;;
        --cuda)       GPU_BACKEND="cuda"; shift ;;
        --cuda12)     GPU_BACKEND="cuda12"; shift ;;
        --vulkan)     GPU_BACKEND="vulkan"; shift ;;
        --profile)    PROFILE="$2"; shift 2 ;;
        --tag)        IMAGE_TAG="$2"; shift 2 ;;
        --skip-stage) SKIP_STAGE=true; shift ;;
        --engine)     ENGINE="$2"; shift 2 ;;
        --base-image) BASE_IMAGE="$2"; shift 2 ;;
        --push)       PUSH=true; shift ;;
        --registry)   REGISTRY="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./build.sh --cuda|--cuda12|--rocm|--vulkan [OPTIONS]"
            echo ""
            echo "Build a self-contained llama-server container image."
            echo ""
            echo "Backend (required — pick one):"
            echo "  --cuda              NVIDIA GPUs (CUDA 13)"
            echo "  --cuda12            NVIDIA GPUs (CUDA 12)"
            echo "  --rocm              AMD discrete GPUs"
            echo "  --vulkan            Vulkan (AMD iGPU, Intel, broad compat)"
            echo ""
            echo "Options:"
            echo "  --profile NAME      Use a model profile from profiles/<NAME>.sh"
            echo "  --base-image IMG    Override the base image entirely"
            echo "  --tag TAG           Custom image tag (default: auto-generated)"
            echo "  --skip-stage        Don't auto-stage models (models/ must exist)"
            echo "  --engine CMD        Container engine: podman or docker (auto-detected)"
            echo "  --push              Push image to container registry after building"
            echo "  --registry URL      Registry prefix (default: tendi.lan:4200/djkunkel)"
            echo "  --help              Show this help"
            echo ""
            echo "Examples:"
            echo "  ./build.sh --profile qwen3.5-4b --cuda"
            echo "  ./build.sh --rocm --tag my-model:latest"
            echo "  ./build.sh --cuda --push"
            echo ""
            echo "Create a new profile:"
            echo "  ./new-profile.sh unsloth/Qwen3.5-4B-GGUF"
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            echo "Run ./build.sh --help for usage" >&2
            exit 1
            ;;
    esac
done

# ── Require a GPU backend ────────────────────────────────────────────────────

if [[ -z "$GPU_BACKEND" && -z "$BASE_IMAGE" ]]; then
    echo "error: GPU backend is required. Specify --cuda, --cuda12, --rocm, or --vulkan" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  ./build.sh --cuda                            # NVIDIA (CUDA 13)" >&2
    echo "  ./build.sh --cuda12                          # NVIDIA (CUDA 12)" >&2
    echo "  ./build.sh --rocm                            # AMD discrete" >&2
    echo "  ./build.sh --vulkan                          # Vulkan" >&2
    echo "  ./build.sh --profile qwen3.5-4b --cuda       # with a profile" >&2
    echo "" >&2
    echo "Run ./build.sh --help for full usage" >&2
    exit 1
fi

# ── Load profile (if specified) ──────────────────────────────────────────────

# DEFAULTS will hold the runtime defaults to bake into the image.
DEFAULTS=()

if [[ -n "$PROFILE" ]]; then
    PROFILE_FILE="$SCRIPT_DIR/profiles/${PROFILE}.sh"
    if [[ ! -f "$PROFILE_FILE" ]]; then
        echo "error: profile not found: $PROFILE_FILE" >&2
        echo "" >&2
        echo "Available profiles:" >&2
        for p in "$SCRIPT_DIR"/profiles/*.sh; do
            [[ -f "$p" ]] && echo "  $(basename "${p%.sh}")" >&2
        done
        exit 1
    fi

    echo "==> profile: $PROFILE"

    # Source the profile — may set REPO, FILES, DEFAULTS
    # shellcheck source=/dev/null
    source "$PROFILE_FILE"
fi

# If no profile or profile didn't set DEFAULTS, use fallback
if [[ ${#DEFAULTS[@]} -eq 0 ]]; then
    DEFAULTS=("${FALLBACK_DEFAULTS[@]}")
fi

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
        cuda12) BASE_IMAGE="$BASE_IMAGE_CUDA12" ;;
        rocm)   BASE_IMAGE="$BASE_IMAGE_ROCM" ;;
        vulkan) BASE_IMAGE="$BASE_IMAGE_VULKAN" ;;
        *)      echo "error: unknown backend: $GPU_BACKEND" >&2; exit 1 ;;
    esac
fi

echo "==> base image: $BASE_IMAGE"
echo "==> GPU backend: ${GPU_BACKEND:-custom}"

# ── Auto-stage models if needed ──────────────────────────────────────────────

gguf_count=$(find "$MODELS_DIR" -maxdepth 1 -name '*.gguf' 2>/dev/null | wc -l)
need_stage=false

if [[ "$gguf_count" -eq 0 ]]; then
    need_stage=true
elif [[ -n "$PROFILE" && -f "$MANIFEST" ]]; then
    # Check if staged model matches the requested profile (repo + files)
    MANIFEST_REPO=""
    MANIFEST_FILES=""
    # shellcheck source=/dev/null
    source "$MANIFEST"
    MANIFEST_REPO="$REPO"
    MANIFEST_FILES="$FILES"
    # Re-source the profile to restore REPO/FILES (MANIFEST source overwrites them)
    # shellcheck source=/dev/null
    source "$PROFILE_FILE"
    PROFILE_FILES="${FILES[*]}"
    if [[ "$MANIFEST_REPO" != "$REPO" ]]; then
        echo "==> staged repo ($MANIFEST_REPO) doesn't match profile ($REPO)"
        need_stage=true
    elif [[ "$MANIFEST_FILES" != "$PROFILE_FILES" ]]; then
        echo "==> staged files ($MANIFEST_FILES) don't match profile ($PROFILE_FILES)"
        need_stage=true
    fi
fi

if $need_stage && ! $SKIP_STAGE; then
    if [[ -n "$PROFILE" ]]; then
        echo "==> staging model for profile: $PROFILE..."
        "$SCRIPT_DIR/models.sh" --profile "$PROFILE"
    else
        echo "==> no models staged, running models.sh with defaults..."
        "$SCRIPT_DIR/models.sh"
    fi
    echo ""
elif $need_stage && $SKIP_STAGE; then
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
# shellcheck source=/dev/null
source "$MANIFEST"

if [[ -z "$REPO" || -z "$COMMIT" ]]; then
    echo "error: MANIFEST is missing REPO or COMMIT" >&2
    exit 1
fi

echo "==> repo: $REPO"
echo "==> commit: ${COMMIT:0:12}..."
echo "==> files: $FILES"

# ── Generate defaults.conf ───────────────────────────────────────────────────

# Write the runtime defaults as a file that gets baked into the image.
# One flag-group per line (flag + value on the same line).
{
    echo "# Runtime defaults — generated by build.sh"
    echo "# Profile: ${PROFILE:-none}"

    local_i=0
    while (( local_i < ${#DEFAULTS[@]} )); do
        flag="${DEFAULTS[$local_i]}"
        # Check if next element is a value (not a flag)
        if (( local_i + 1 < ${#DEFAULTS[@]} )) && [[ "${DEFAULTS[$((local_i + 1))]}" != -* ]]; then
            val="${DEFAULTS[$((local_i + 1))]}"
            # Quote values that contain spaces, quotes, or newlines so
            # entrypoint.sh can safely eval them back into args.
            # Uses $'...' quoting with \n escapes so the entire flag+value
            # stays on a single line (defaults.conf is line-oriented).
            if [[ "$val" == *[[:space:]]* || "$val" == *\'* || "$val" == *\"* ]]; then
                # Escape backslashes first, then single-quotes, then newlines
                val="${val//\\/\\\\}"
                val="${val//\'/\\\'}"
                val="${val//$'\n'/\\n}"
                val="\$'${val}'"
            fi
            echo "$flag $val"
            local_i=$((local_i + 2))
        else
            echo "$flag"
            local_i=$((local_i + 1))
        fi
    done
} > "$DEFAULTS_FILE"

echo "==> defaults: $DEFAULTS_FILE"

# ── Compute build args ───────────────────────────────────────────────────────

# Convert repo name to HF cache directory name: org/name → models--org--name
HF_REPO_CACHE="models--${REPO//\//--}"

echo "==> cache dir: $HF_REPO_CACHE"

# ── Generate image tag if not provided ───────────────────────────────────────

if [[ -z "$IMAGE_TAG" ]]; then
    tag_backend="${GPU_BACKEND:-custom}"

    if [[ -n "$PROFILE" ]]; then
        # Profile name is the canonical image identity.
        IMAGE_TAG="thinkpod:${PROFILE}-${tag_backend}"
    else
        # No profile — derive a name from the HF repo + quantization.
        local_name="${REPO##*/}"            # Qwen3.5-4B-GGUF
        local_name="${local_name%-GGUF}"    # Qwen3.5-4B
        local_name="${local_name,,}"        # qwen3.5-4b (lowercase)

        # Try to extract quantization from filenames
        quant=""
        set -f
        for f in $FILES; do
            if [[ "$f" != *mmproj* && "$f" =~ [-_](Q[0-9A-Z_]+)\. ]]; then
                quant="${BASH_REMATCH[1],,}"  # q4_k_m
                break
            fi
        done
        set +f

        if [[ -n "$quant" ]]; then
            IMAGE_TAG="thinkpod:${local_name}-${quant}-${tag_backend}"
        else
            IMAGE_TAG="thinkpod:${local_name}-${tag_backend}"
        fi
    fi
fi

echo "==> image tag: $IMAGE_TAG"
echo ""

# ── Build ────────────────────────────────────────────────────────────────────

echo "==> building image..."
$ENGINE build \
    -f "$SCRIPT_DIR/Containerfile" \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg "HF_REPO=$REPO" \
    --build-arg "HF_REPO_CACHE=$HF_REPO_CACHE" \
    --build-arg "COMMIT_HASH=$COMMIT" \
    -t "$IMAGE_TAG" \
    "$SCRIPT_DIR"

echo ""
echo "==> build complete: $IMAGE_TAG"
echo ""

# ── Push to registry (if requested) ──────────────────────────────────────────

if $PUSH; then
    # Extract just the image name and tag parts: thinkpod:tag
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
    case "${GPU_BACKEND:-custom}" in
        cuda|cuda12)
            echo "      --device nvidia.com/gpu=all \\"
            echo "      --security-opt label=disable \\"
            ;;
        rocm)
            echo "      --device /dev/kfd --device /dev/dri \\"
            echo "      --security-opt seccomp=unconfined \\"
            echo "      --security-opt label=disable \\"
            ;;
        vulkan)
            echo "      --device /dev/dri \\"
            echo "      --security-opt label=disable \\"
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
echo "Override defaults at runtime:"
echo ""
echo "  $ENGINE run --rm -it \\"
echo "      --network host \\"
print_device_flags
echo "      $RUN_IMAGE -- -c 8192 --reasoning off"
