#!/usr/bin/env bash
#
# Run llama-server from a profile.
#
# Binary backends (--cpu, --rocm, --rocm-nightly, --vulkan) run a cached
# llama.cpp release binary from bin/. Container backends (--cuda, --cuda12)
# run an upstream ghcr.io image via podman or docker.
#
# Backend lifecycle (download, update, prune, selection) is handled by
# backends.sh, which records the current selection in the gitignored
# bin/current file. run.sh reads that file via `backends.sh current`; if no
# build is cached it asks `backends.sh update` to fetch one. See
# `./backends.sh --help` for managing backends directly.
#
# Usage:
#   ./run.sh --cpu           --profile NAME [--dry-run] [-- extra llama-server flags]
#   ./run.sh --rocm          --profile NAME [--dry-run] [-- extra llama-server flags]
#   ./run.sh --rocm-nightly  --profile NAME [--dry-run] [-- extra llama-server flags]
#   ./run.sh --vulkan        --profile NAME [--dry-run] [-- extra llama-server flags]
#   ./run.sh --cuda          --profile NAME [--dry-run] [-- extra llama-server flags]
#   ./run.sh --cuda12        --profile NAME [--dry-run] [-- extra llama-server flags]
#
# Binary backends:
#   --cpu           Ubuntu x64 CPU-only build (upstream llama.cpp release)
#   --rocm          Ubuntu x64 ROCm build     (upstream llama.cpp release)
#   --rocm-nightly  Ubuntu x64 ROCm build     (lemonade-sdk/llamacpp-rocm nightly)
#   --vulkan        Ubuntu x64 Vulkan build   (upstream llama.cpp release)
#
# Container backends:
#   --cuda          NVIDIA CUDA 13 (ghcr.io/ggml-org/llama.cpp:server-cuda13)
#   --cuda12        NVIDIA CUDA 12 (ghcr.io/ggml-org/llama.cpp:server-cuda)
#                   CUDA containers require the NVIDIA Container Toolkit
#                   (nvidia-ctk) for GPU access; run.sh checks for it.
#
# Environment:
#   LLAMA_RELEASE       Pin a specific release tag for this run (binary
#                       backends); forwarded to backends.sh. Default: the
#                       current selection in bin/current, or latest on update.
#   HF_HUB              HuggingFace cache directory (default: ~/.cache/huggingface/hub)
#                       Created automatically if missing so llama-server can
#                       download the model on first run.
#   HOST                Bind address (default: 0.0.0.0)
#   PORT                Bind port    (default: 8080)
#   IMAGE               Override container image (container backends only)
#   ENGINE              Container engine: podman or docker (auto-detected)
#
# Backend cache + selection (managed by backends.sh, see its --help):
#   bin/<backend>/<tag>/           — cpu, rocm, vulkan
#   bin/rocm-nightly/<tag>-<gfx>/  — rocm-nightly
#   bin/current                    — gitignored state file tracking the
#                                    selected build/image per backend.
# ROCM_VERSION, ROCM_NIGHTLY_REPO, ROCM_GFX, and ARCH are honored by
# backends.sh (inherited from the environment) when downloading.

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

# ── Path resolution ───────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles"
BACKENDS_SH="$SCRIPT_DIR/backends.sh"
DEFAULT_TEMPLATE_DIR="$SCRIPT_DIR/templates"
TEMPLATE_DIR=""

# ── Helpers ───────────────────────────────────────────────────────────────────

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Is this a container backend?
_is_container() {
    [[ "$1" == "cuda" || "$1" == "cuda12" ]]
}

# Display label for the summary (version details come from backends.sh).
backend_label() {
    case "$1" in
        cpu)          echo "CPU (Ubuntu x64)" ;;
        rocm)         echo "AMD ROCm" ;;
        rocm-nightly) echo "AMD ROCm nightly" ;;
        vulkan)       echo "Vulkan" ;;
        cuda)         echo "NVIDIA CUDA 13 (container)" ;;
        cuda12)       echo "NVIDIA CUDA 12 (container)" ;;
    esac
}

# Verify the NVIDIA Container Toolkit is installed for CUDA container backends.
# The --device nvidia.com/gpu=all flag resolves via CDI, which the toolkit
# generates; without it the container starts but cannot see the GPU.
# $1 = "fatal" to exit with install instructions, "warn" to only print them.
_check_nvidia_toolkit() {
    command -v nvidia-ctk &>/dev/null && return 0
    local msg
    msg="NVIDIA Container Toolkit (nvidia-ctk) is required for --$BACKEND so the
container can access the GPU, but it was not found on this host.

See the official install guide for your distribution:
    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

Then re-run: ./run.sh --$BACKEND --profile $PROFILE"
    if [[ "$1" == "fatal" ]]; then
        die "$msg"
    else
        echo "warning: $msg" >&2
    fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpu)          BACKEND="cpu";          shift ;;
        --rocm)         BACKEND="rocm";         shift ;;
        --rocm-nightly) BACKEND="rocm-nightly"; shift ;;
        --vulkan)       BACKEND="vulkan";       shift ;;
        --cuda)         BACKEND="cuda";         shift ;;
        --cuda12)       BACKEND="cuda12";       shift ;;
        --profile)
            [[ -z "${2:-}" ]] && die "--profile requires a name"
            PROFILE="$2"
            shift 2
            ;;
        --release)
            [[ -z "${2:-}" ]] && die "--release requires a tag (e.g. --release b9785)"
            LLAMA_RELEASE="$2"
            shift 2
            ;;
        --template-dir)
            [[ -z "${2:-}" ]] && die "--template-dir requires a path"
            TEMPLATE_DIR="$2"
            shift 2
            ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: ./run.sh --BACKEND --profile NAME [--dry-run] [-- LLAMA_ARGS...]"
            echo ""
            echo "Binary backends (run a cached llama.cpp release binary):"
            echo "  --cpu           Ubuntu x64 CPU-only"
            echo "  --rocm          Ubuntu x64 ROCm (upstream release)"
            echo "  --rocm-nightly  Ubuntu x64 ROCm (lemonade-sdk nightly)"
            echo "  --vulkan        Ubuntu x64 Vulkan"
            echo ""
            echo "Container backends (run a ghcr.io image via podman/docker):"
            echo "  --cuda          NVIDIA CUDA 13 (requires nvidia-container-toolkit)"
            echo "  --cuda12        NVIDIA CUDA 12 (requires nvidia-container-toolkit)"
            echo ""
            echo "Options:"
            echo "  --profile NAME      Source profiles/<NAME>.sh (required)"
            echo "  --release TAG       Pin the release tag (binary backends)"
            echo "  --template-dir DIR  Mount DIR at /templates (container backends;"
            echo "                      defaults to templates/ if present)"
            echo "  --dry-run           Print the command without executing it"
            echo "  -- ARGS             Forward remaining args to llama-server"
            echo ""
            echo "Environment:"
            echo "  LLAMA_RELEASE       Pin a release tag for this run (binary backends)"
            echo "  HF_HUB              HuggingFace cache (default: ~/.cache/huggingface/hub)"
            echo "  HOST                Bind address (default: ${HOST})"
            echo "  PORT                Bind port (default: ${PORT})"
            echo "  IMAGE               Override container image (container backends)"
            echo "  ENGINE              Container engine: podman or docker (auto-detected)"
            echo ""
            echo "Backend management: see ./backends.sh --help (update/use/list/prune)."
            exit 0
            ;;
        --)
            shift
            EXTRA_ARGS=("$@")
            break
            ;;
        -*)  die "unknown option: $1 (try --help)" ;;
        *)   die "unexpected argument: $1 (try --help)" ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────────────────────

[[ -z "$BACKEND" ]] && die "a backend is required (try --help)"

# ── Profile selection ─────────────────────────────────────────────────────────
# If --profile was not given, list available profiles and prompt for one.

if [[ -z "$PROFILE" ]]; then
    mapfile -t profile_files < <(ls "$PROFILES_DIR"/*.sh 2>/dev/null | sort)
    [[ ${#profile_files[@]} -eq 0 ]] && die "no profiles found in $PROFILES_DIR"

    echo "Available profiles:"
    echo ""
    PS3=$'\nSelect a profile: '
    select profile_file in "${profile_files[@]##*/}"; do
        [[ -n "$profile_file" ]] && break
        echo "Invalid selection, try again."
    done
    PROFILE="${profile_file%.sh}"
    profile_file="$PROFILES_DIR/$profile_file"
    echo ""
else
    profile_file="$PROFILES_DIR/${PROFILE}.sh"
    [[ ! -f "$profile_file" ]] && die "profile not found: $profile_file"
fi

# ── Source profile ────────────────────────────────────────────────────────────

REPO=""
FILES=()
DEFAULTS=()
TEMPLATE=""

# shellcheck source=/dev/null
source "$profile_file"

[[ -z "$REPO" ]]         && die "profile $PROFILE did not set REPO"
[[ ${#FILES[@]} -eq 0 ]] && die "profile $PROFILE did not set FILES"

# Pick the first non-mmproj entry as the primary model file.
HF_FILE=""
for f in "${FILES[@]}"; do
    if [[ "$f" != mmproj* && "$f" != mtp-* ]]; then
        HF_FILE="$f"
        break
    fi
done
[[ -z "$HF_FILE" ]] && die "could not find a primary model file in FILES for profile $PROFILE"

# ── Resolve profile template ──────────────────────────────────────────────────

template_args=()
if [[ -n "$TEMPLATE" ]]; then
    if _is_container "$BACKEND"; then
        # Container: verify the file exists on the host and inject container path.
        [[ -z "$TEMPLATE_DIR" && -d "$DEFAULT_TEMPLATE_DIR" ]] && TEMPLATE_DIR="$DEFAULT_TEMPLATE_DIR"
        [[ -z "$TEMPLATE_DIR" ]] && die "profile sets TEMPLATE=$TEMPLATE but no templates directory found"
        [[ ! -f "$TEMPLATE_DIR/$TEMPLATE" ]] && die "template not found: $TEMPLATE_DIR/$TEMPLATE"
        template_args=(--jinja --chat-template-file "/templates/$TEMPLATE")
    else
        # Binary: resolve against local templates dir.
        template_file="$SCRIPT_DIR/templates/$TEMPLATE"
        [[ ! -f "$template_file" ]] && die "template not found: $template_file"
        template_args=(--jinja --chat-template-file "$template_file")
    fi
fi

# ── Build llama-server args ───────────────────────────────────────────────────

server_args=(
    -hf "$REPO"
    --hf-file "$HF_FILE"
    --host "$HOST"
    --port "$PORT"
    --metrics
)
[[ ${#template_args[@]} -gt 0 ]] && server_args+=("${template_args[@]}")
[[ ${#DEFAULTS[@]}      -gt 0 ]] && server_args+=("${DEFAULTS[@]}")
[[ ${#EXTRA_ARGS[@]}    -gt 0 ]] && server_args+=("${EXTRA_ARGS[@]}")

# ── Container backend ─────────────────────────────────────────────────────────

if _is_container "$BACKEND"; then

    # Detect container engine.
    if [[ -z "$ENGINE" ]]; then
        if command -v podman &>/dev/null; then
            ENGINE="podman"
        elif command -v docker &>/dev/null; then
            ENGINE="docker"
        else
            die "neither podman nor docker found"
        fi
    fi

    # CUDA containers need the NVIDIA Container Toolkit for GPU access; fail
    # fast with install instructions (warn only in --dry-run so the command
    # can still be previewed on a host without the toolkit).
    if [[ "$BACKEND" == "cuda" || "$BACKEND" == "cuda12" ]]; then
        if $DRY_RUN; then
            _check_nvidia_toolkit warn
        else
            _check_nvidia_toolkit fatal
        fi
    fi

    # Select image: honor an explicit IMAGE override, otherwise ask backends.sh
    # for the current selection (falls back to the default image if unset).
    [[ -x "$BACKENDS_SH" ]] || die "backends.sh not found at $BACKENDS_SH"
    if [[ -z "${IMAGE:-}" ]]; then
        IMAGE="$("$BACKENDS_SH" current --backend "$BACKEND")" \
            || die "could not resolve container image for $BACKEND"
    fi

    # Device + security flags.
    mapfile -t dev_flags < <(
        case "$BACKEND" in
            cuda|cuda12)
                printf '%s\n' "--device" "nvidia.com/gpu=all" "--security-opt" "label=disable"
                ;;
        esac
    )

    # Template volume.
    if [[ -z "$TEMPLATE_DIR" && -d "$DEFAULT_TEMPLATE_DIR" ]]; then
        TEMPLATE_DIR="$DEFAULT_TEMPLATE_DIR"
    fi
    if [[ -n "$TEMPLATE_DIR" ]]; then
        [[ ! -d "$TEMPLATE_DIR" ]] && die "template directory not found: $TEMPLATE_DIR"
        TEMPLATE_DIR="$(cd "$TEMPLATE_DIR" && pwd)"
    fi

    # The HuggingFace cache is bind-mounted into the container; create it on
    # demand so a fresh host can download the model on first run. llama-server
    # fetches weights lazily via -hf, so an empty cache is fine.
    if [[ ! -d "$HF_HUB" ]]; then
        if $DRY_RUN; then
            info "(dry-run) would create HuggingFace cache at $HF_HUB"
        else
            info "creating HuggingFace cache at $HF_HUB (model downloads on first run)"
            mkdir -p "$HF_HUB"
        fi
    fi

    # Summary.
    info "profile:  $PROFILE"
    info "model:    $REPO / $HF_FILE"
    info "backend:  $(backend_label "$BACKEND")"
    info "image:    $IMAGE"
    info "cache:    $HF_HUB"
    [[ -n "$TEMPLATE_DIR" ]] && info "templates: $TEMPLATE_DIR → /templates"
    [[ -n "$TEMPLATE"     ]] && info "template:  $TEMPLATE"
    info "endpoint: http://localhost:${PORT}"
    echo ""

    if $DRY_RUN; then
        info "dry-run: command that would be executed:"
        echo ""
        echo "$ENGINE run --rm -it \\"
        echo "    --network host \\"
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
        [[ -n "$TEMPLATE_DIR" ]] && echo "    -v \"$TEMPLATE_DIR:/templates:ro\" \\"
        echo "    \"$IMAGE\" \\"
        last=$(( ${#server_args[@]} - 1 ))
        for (( j=0; j<${#server_args[@]}; j++ )); do
            arg="${server_args[$j]}"
            [[ "$arg" == *' '* || "$arg" == *$'\n'* ]] && arg="$(printf '%q' "$arg")"
            (( j < last )) && echo "    $arg \\" || echo "    $arg"
        done
        exit 0
    fi

    template_vol=()
    [[ -n "$TEMPLATE_DIR" ]] && template_vol=(-v "$TEMPLATE_DIR:/templates:ro")

    exec "$ENGINE" run --rm -it \
        --network host \
        "${dev_flags[@]}" \
        -v "$HF_HUB:/root/.cache/huggingface/hub" \
        "${template_vol[@]}" \
        "$IMAGE" \
        "${server_args[@]}"
fi

# ── Binary backend ────────────────────────────────────────────────────────────

# Resolve the cached binary directory for the selected backend.
#   1. If --release was pinned, use that exact build (downloading if missing).
#   2. Else read the current selection from bin/current via backends.sh.
#   3. Else fall back to the newest cached build (handled inside backends.sh).
#   4. If nothing is cached, ask backends.sh to download one and re-resolve.
[[ -x "$BACKENDS_SH" ]] || die "backends.sh not found at $BACKENDS_SH"

resolve_cache_dir() {
    if [[ -n "${LLAMA_RELEASE:-}" ]]; then
        "$BACKENDS_SH" current --backend "$BACKEND" --release "$LLAMA_RELEASE"
    else
        "$BACKENDS_SH" current --backend "$BACKEND"
    fi
}

if CACHE_DIR="$(resolve_cache_dir 2>/dev/null)"; then
    :
else
    if [[ -n "${LLAMA_RELEASE:-}" ]]; then
        # A pinned --release is a one-off: download it but leave bin/current
        # (the persistent default) untouched.
        info "release ${LLAMA_RELEASE} not cached — downloading"
        "$BACKENDS_SH" update --"$BACKEND" --release "$LLAMA_RELEASE" --no-mark
    else
        info "no cached ${BACKEND} build — downloading latest"
        "$BACKENDS_SH" update --"$BACKEND"
    fi
    CACHE_DIR="$(resolve_cache_dir)" \
        || die "backend still not available after update — run './backends.sh update --${BACKEND}' manually"
fi

SERVER_BIN="$CACHE_DIR/llama-server"
[[ -x "$SERVER_BIN" ]] || die "llama-server not found at $SERVER_BIN"

# Display tag from the cache dir name (strip the gfx suffix for rocm-nightly).
RELEASE_TAG="$(basename "$CACHE_DIR")"

# Summary.
info "profile:  $PROFILE"
info "model:    $REPO / $HF_FILE"
info "backend:  $(backend_label "$BACKEND")"
info "release:  $RELEASE_TAG"
info "binary:   $SERVER_BIN"
[[ -n "$TEMPLATE" ]] && info "template: $SCRIPT_DIR/templates/$TEMPLATE"
info "endpoint: http://localhost:${PORT}"
echo ""

if $DRY_RUN; then
    info "dry-run: command that would be executed:"
    echo ""
    echo "\"$SERVER_BIN\" \\"
    last=$(( ${#server_args[@]} - 1 ))
    for (( j=0; j<${#server_args[@]}; j++ )); do
        arg="${server_args[$j]}"
        [[ "$arg" == *' '* || "$arg" == *$'\n'* ]] && arg="$(printf '%q' "$arg")"
        (( j < last )) && echo "    $arg \\" || echo "    $arg"
    done
    exit 0
fi

exec "$SERVER_BIN" "${server_args[@]}"
