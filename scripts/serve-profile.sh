#!/usr/bin/env bash
#
# Run a llama.cpp upstream container with the HuggingFace cache mounted,
# using settings derived from a thinkpod profile.
#
# Replaces serve.sh — no build step needed. Models are loaded directly
# from the local HF cache (and downloaded there if missing).
#
# Usage:
#   ./serve-profile.sh --cuda   --profile NAME
#   ./serve-profile.sh --rocm   --profile NAME [--dry-run]
#   ./serve-profile.sh --vulkan --profile NAME [-- extra llama-server flags]
#
# Backends:
#   --cuda      NVIDIA CUDA 13 (server-cuda13)
#   --cuda12    NVIDIA CUDA 12 (server-cuda)
#   --rocm      AMD ROCm       (server-rocm)
#   --vulkan    Vulkan          (server-vulkan)
#
# Flags after -- are forwarded to llama-server and override profile defaults.
#
# Environment:
#   HF_HUB    HuggingFace cache directory (default: ~/.cache/huggingface/hub)
#   IMAGE     Override the upstream image (default: per-backend ghcr.io tag)
#   HOST      Bind address (default: 0.0.0.0)
#   PORT      Bind port    (default: 8080)
#   ENGINE    Container engine: podman or docker (auto-detected)

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

HF_HUB="${HF_HUB:-$HOME/.cache/huggingface/hub}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
ENGINE="${ENGINE:-}"

BACKEND=""
PROFILE=""
DRY_RUN=false
EXTRA_ARGS=()

# Resolve the directory that contains the profiles/ folder.
# This script lives in scripts/; profiles/ is one level up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/profiles"

# ── Detect container engine ───────────────────────────────────────────────────

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

# ── Helpers ───────────────────────────────────────────────────────────────────

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Return the upstream image tag for a given backend.
default_image() {
    case "$1" in
        cuda)    echo "ghcr.io/ggml-org/llama.cpp:server-cuda13" ;;
        cuda12)  echo "ghcr.io/ggml-org/llama.cpp:server-cuda"   ;;
        rocm)    echo "ghcr.io/ggml-org/llama.cpp:server-rocm"   ;;
        vulkan)  echo "ghcr.io/ggml-org/llama.cpp:server-vulkan" ;;
    esac
}

# Return the device + security flags for a given backend as separate words,
# one flag per line, so they can be safely eval'd into an array.
device_flags() {
    case "$1" in
        cuda|cuda12)
            printf '%s\n' "--device" "nvidia.com/gpu=all" "--security-opt" "label=disable"
            ;;
        rocm)
            printf '%s\n' "--device" "/dev/kfd" "--device" "/dev/dri" \
                          "--security-opt" "seccomp=unconfined" "--security-opt" "label=disable"
            ;;
        vulkan)
            printf '%s\n' "--device" "/dev/dri" "--security-opt" "label=disable"
            ;;
    esac
}

# Human-readable backend description
backend_label() {
    case "$1" in
        cuda)    echo "NVIDIA CUDA 13" ;;
        cuda12)  echo "NVIDIA CUDA 12" ;;
        rocm)    echo "AMD ROCm" ;;
        vulkan)  echo "Vulkan" ;;
    esac
}

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cuda)    BACKEND="cuda";   shift ;;
        --cuda12)  BACKEND="cuda12"; shift ;;
        --rocm)    BACKEND="rocm";   shift ;;
        --vulkan)  BACKEND="vulkan"; shift ;;
        --profile)
            [[ -z "${2:-}" ]] && die "--profile requires a name (e.g. --profile qwen3.5-4b)"
            PROFILE="$2"
            shift 2
            ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: ./serve-profile.sh --BACKEND --profile NAME [--dry-run] [-- LLAMA_ARGS...]"
            echo ""
            echo "Backends:  --cuda  --cuda12  --rocm  --vulkan"
            echo ""
            echo "Options:"
            echo "  --profile NAME   Source profiles/<NAME>.sh for model + defaults (required)"
            echo "  --dry-run        Print the run command without executing it"
            echo "  -- ARGS          Forward remaining args to llama-server (override profile defaults)"
            echo ""
            echo "Environment:"
            echo "  HF_HUB    HuggingFace cache dir (default: ~/.cache/huggingface/hub)"
            echo "  IMAGE     Override the upstream image"
            echo "  HOST      Bind address (default: 0.0.0.0)"
            echo "  PORT      Bind port    (default: 8080)"
            echo "  ENGINE    Container engine: podman or docker (auto-detected)"
            exit 0
            ;;
        --)
            shift
            EXTRA_ARGS=("$@")
            break
            ;;
        -*)
            die "unknown option: $1 (try --help)"
            ;;
        *)
            die "unexpected argument: $1 (try --help)"
            ;;
    esac
done

# ── Validate required args ────────────────────────────────────────────────────

[[ -z "$BACKEND" ]]  && die "a backend is required: --cuda, --cuda12, --rocm, or --vulkan"
[[ -z "$PROFILE" ]]  && die "--profile NAME is required"

profile_file="$PROFILES_DIR/${PROFILE}.sh"
[[ ! -f "$profile_file" ]] && die "profile not found: $profile_file"

# ── Source profile ────────────────────────────────────────────────────────────

REPO=""
FILES=()
DEFAULTS=()

# shellcheck source=/dev/null
source "$profile_file"

[[ -z "$REPO" ]]         && die "profile $PROFILE did not set REPO"
[[ ${#FILES[@]} -eq 0 ]] && die "profile $PROFILE did not set FILES"

# ── Derive HF_FILE ────────────────────────────────────────────────────────────
# Pick the first entry in FILES that isn't an mmproj file.
# -hf expects only the repo (org/name); the specific GGUF is passed via --hf-file.

HF_FILE=""
for f in "${FILES[@]}"; do
    if [[ "$f" != mmproj* ]]; then
        HF_FILE="$f"
        break
    fi
done

[[ -z "$HF_FILE" ]] && die "could not find a non-mmproj model file in FILES for profile $PROFILE"

# ── Preflight checks ──────────────────────────────────────────────────────────

[[ ! -d "$HF_HUB" ]] && die "HuggingFace cache not found at $HF_HUB (set HF_HUB to override)"

# ── Build llama-server args from DEFAULTS ─────────────────────────────────────
# DEFAULTS is an array of flag+value pairs straight from the profile.
# We pass them directly — entrypoint merge semantics don't apply here since
# we're not going through entrypoint.sh. Instead, user EXTRA_ARGS are appended
# last so they can override any profile default.

server_args=(
    -hf "$REPO"
    --hf-file "$HF_FILE"
    --host "$HOST"
    --port "$PORT"
    --metrics
)

# Append profile defaults
if [[ ${#DEFAULTS[@]} -gt 0 ]]; then
    server_args+=("${DEFAULTS[@]}")
fi

# Append user overrides (after --)
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    server_args+=("${EXTRA_ARGS[@]}")
fi

# ── Select image ──────────────────────────────────────────────────────────────

IMAGE="${IMAGE:-$(default_image "$BACKEND")}"

# ── Build device flags array ──────────────────────────────────────────────────

mapfile -t dev_flags < <(device_flags "$BACKEND")

# ── Print summary ─────────────────────────────────────────────────────────────

info "profile:  $PROFILE"
info "model:    $REPO / $HF_FILE"
info "backend:  $(backend_label "$BACKEND")"
info "image:    $IMAGE"
info "cache:    $HF_HUB"
info "endpoint: http://localhost:${PORT}"
echo ""

# ── Dry-run ───────────────────────────────────────────────────────────────────

if $DRY_RUN; then
    info "dry-run: command that would be executed:"
    echo ""

    # Build a single printable string of device flags (pairs on same line)
    dev_flags_str=""
    i=0
    while (( i < ${#dev_flags[@]} )); do
        flag="${dev_flags[$i]}"
        # Flags like --device and --security-opt take a value as the next element
        if [[ "$flag" == --device || "$flag" == --security-opt ]]; then
            dev_flags_str+=" $flag ${dev_flags[$((i+1))]}"
            i=$(( i + 2 ))
        else
            dev_flags_str+=" $flag"
            i=$(( i + 1 ))
        fi
    done

    # Build printable server args, quoting any multi-word / multi-line values
    server_args_str=""
    for arg in "${server_args[@]}"; do
        if [[ "$arg" == *' '* || "$arg" == *$'\n'* ]]; then
            server_args_str+=" $(printf '%q' "$arg")"
        else
            server_args_str+=" $arg"
        fi
    done

    echo "$ENGINE run --rm -it \\"
    echo "    --network host \\"
    # Print each flag pair on its own continuation line
    i=0
    while (( i < ${#dev_flags[@]} )); do
        flag="${dev_flags[$i]}"
        if [[ "$flag" == --device || "$flag" == --security-opt ]]; then
            echo "    $flag ${dev_flags[$((i+1))]} \\"
            i=$(( i + 2 ))
        else
            echo "    $flag \\"
            i=$(( i + 1 ))
        fi
    done
    echo "    -v \"$HF_HUB:/root/.cache/huggingface/hub\" \\"
    echo "    \"$IMAGE\" \\"
    last_idx=$(( ${#server_args[@]} - 1 ))
    for (( j=0; j<${#server_args[@]}; j++ )); do
        arg="${server_args[$j]}"
        if [[ "$arg" == *' '* || "$arg" == *$'\n'* ]]; then
            printed="$(printf '%q' "$arg")"
        else
            printed="$arg"
        fi
        if (( j < last_idx )); then
            echo "    $printed \\"
        else
            echo "    $printed"
        fi
    done

    exit 0
fi

# ── Run ───────────────────────────────────────────────────────────────────────

exec "$ENGINE" run --rm -it \
    --network host \
    "${dev_flags[@]}" \
    -v "$HF_HUB:/root/.cache/huggingface/hub" \
    "$IMAGE" \
    "${server_args[@]}"
