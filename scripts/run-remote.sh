#!/usr/bin/env bash
#
# Pull and run a thinkpod container image from an OCI registry.
#
# Queries the registry for available images, presents an interactive menu,
# auto-detects the GPU backend from the tag, and runs with the correct
# device flags.  Works with any OCI-compliant registry (Gitea, GHCR,
# Docker Hub, Quay, Harbor, etc.).
#
# Usage:
#   ./run-remote.sh                                # interactive: pick from registry
#   ./run-remote.sh qwen3.5-4b-q4_k_m-vulkan       # run a specific tag directly
#   ./run-remote.sh --list                         # just list available images
#   ./run-remote.sh TAG -- -c 8192 --temp 0.7      # pass arbitrary llama-server args
#   ./run-remote.sh --dry-run TAG                  # print the run command without executing
#   ./run-remote.sh --registry host/org TAG        # use a different registry
#
# First-time setup on the remote machine:
#   1. Configure insecure registry (if registry is plain HTTP):
#        echo '[[registry]]
#        location = "tendi.lan:4200"
#        insecure = true' | sudo tee /etc/containers/registries.conf.d/tendi-gitea.conf
#
#   2. Login to the registry:
#        podman login tendi.lan:4200
#
# Passing llama-server args:
#   Anything after -- is forwarded verbatim to the container (overrides defaults).
#
# Environment:
#   REGISTRY    Registry prefix (default: tendi.lan:4200/djkunkel)
#   ENGINE      Container engine: podman or docker (auto-detected)

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────

REGISTRY="${REGISTRY:-tendi.lan:4200/djkunkel}"
IMAGE_NAME="thinkpod"
ENGINE="${ENGINE:-}"
DRY_RUN=false
EXTRA_ARGS=()  # llama-server args passed after --

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

# ── Helpers ──────────────────────────────────────────────────────────────────

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Detect backend from a tag string.
# Returns: cuda, rocm, vulkan, or unknown
detect_backend() {
    local tag="$1"
    case "$tag" in
        *-rocm)    echo "rocm" ;;
        *-cuda12)  echo "cuda12" ;;
        *-cuda)    echo "cuda" ;;
        *-vulkan)  echo "vulkan" ;;
        *)         echo "unknown" ;;
    esac
}

# Human-readable backend description
backend_label() {
    case "$1" in
        cuda)    echo "NVIDIA CUDA 13" ;;
        cuda12)  echo "NVIDIA CUDA 12" ;;
        rocm)    echo "AMD ROCm (discrete GPU)" ;;
        vulkan)  echo "Vulkan (broad compatibility)" ;;
        *)       echo "unknown" ;;
    esac
}

# Print the podman/docker device flags for a backend
device_flags() {
    case "$1" in
        cuda|cuda12)
            echo "--device nvidia.com/gpu=all --security-opt label=disable"
            ;;
        rocm)
            echo "--device /dev/kfd --device /dev/dri --security-opt seccomp=unconfined --security-opt label=disable"
            ;;
        vulkan)
            echo "--device /dev/dri --security-opt label=disable"
            ;;
        *)
            echo ""
            ;;
    esac
}

# ── Fetch available images from registry ─────────────────────────────────────

# Read the base64 auth token from podman/docker auth.json.
# This is the same credential stored by `podman login`.
get_registry_auth() {
    local host="${REGISTRY%%/*}"   # tendi.lan:4200
    local auth_file=""

    # Search for auth.json in standard locations
    for candidate in \
        "${XDG_RUNTIME_DIR:-/tmp}/containers/auth.json" \
        "$HOME/.config/containers/auth.json" \
        "$HOME/.docker/config.json"; do
        if [[ -f "$candidate" ]]; then
            auth_file="$candidate"
            break
        fi
    done

    if [[ -z "$auth_file" ]]; then
        return 1
    fi

    # Extract the base64 auth for our registry host
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
try:
    data = json.load(open('$auth_file'))
    auth = data.get('auths', {}).get('$host', {}).get('auth', '')
    print(auth)
except:
    pass
" 2>/dev/null
    else
        # Fallback: grep for the auth value
        grep -A1 "\"$host\"" "$auth_file" 2>/dev/null | grep '"auth"' | sed 's/.*"auth"[[:space:]]*:[[:space:]]*"//;s/".*//'
    fi
}

fetch_tags() {
    local registry_host="${REGISTRY%%/*}"
    local registry_path="${REGISTRY#*/}"
    local tags_url="http://${registry_host}/v2/${registry_path}/${IMAGE_NAME}/tags/list"

    if ! command -v curl &>/dev/null; then
        die "curl is required to query the registry. Install it first."
    fi

    # Try to get auth from podman/docker login
    local auth
    auth=$(get_registry_auth) || true

    local response
    if [[ -n "$auth" ]]; then
        response=$(curl -sf "$tags_url" -H "Authorization: Basic $auth" 2>/dev/null)
    else
        # Try without auth (in case registry allows anonymous reads)
        response=$(curl -sf "$tags_url" 2>/dev/null)
    fi

    if [[ -z "$response" ]]; then
        die "failed to query registry at $tags_url
       Make sure you have run: podman login $registry_host"
    fi

    # Extract tags from the OCI v2 response: {"name":"...","tags":["tag1","tag2"]}
    if command -v python3 &>/dev/null; then
        echo "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for tag in data.get('tags', []):
    print(tag)
" 2>/dev/null
    else
        # Fallback: crude JSON parsing
        echo "$response" | grep -o '"tags":\[[^]]*\]' | grep -o '"[^"]*"' | sed 's/"//g' | grep -v tags
    fi
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_list() {
    info "querying $REGISTRY for available images..."
    echo ""

    local tags=()
    while IFS= read -r tag; do
        [[ -n "$tag" ]] && tags+=("$tag")
    done < <(fetch_tags | sort)

    if [[ ${#tags[@]} -eq 0 ]]; then
        echo "  (no images found)"
        return
    fi

    printf "  %-40s  %s\n" "IMAGE" "BACKEND"
    printf "  %-40s  %s\n" "-----" "-------"
    for tag in "${tags[@]}"; do
        local backend
        backend=$(detect_backend "$tag")
        printf "  %-40s  %s\n" "$REGISTRY/$IMAGE_NAME:$tag" "$(backend_label "$backend")"
    done
    echo ""
    echo "  ${#tags[@]} image(s) available"
}

cmd_interactive() {
    info "querying $REGISTRY for available images..."

    local tags=()
    while IFS= read -r tag; do
        [[ -n "$tag" ]] && tags+=("$tag")
    done < <(fetch_tags | sort)

    if [[ ${#tags[@]} -eq 0 ]]; then
        die "no images found in the registry"
    fi

    echo ""
    echo "Available images:"
    echo ""

    local i=1
    for tag in "${tags[@]}"; do
        local backend
        backend=$(detect_backend "$tag")
        printf "  %d)  %-40s  [%s]\n" "$i" "$tag" "$(backend_label "$backend")"
        i=$((i + 1))
    done

    echo ""
    printf "Select an image [1-%d]: " "${#tags[@]}"
    read -r choice

    # Validate
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#tags[@]} )); then
        die "invalid selection: $choice"
    fi

    local selected_tag="${tags[$((choice - 1))]}"
    run_image "$selected_tag"
}

cmd_direct() {
    local tag="$1"

    # If the user passed a full image path, extract just the tag
    if [[ "$tag" == *:* ]]; then
        tag="${tag##*:}"
    fi

    run_image "$tag"
}

# ── Run an image ─────────────────────────────────────────────────────────────

run_image() {
    local tag="$1"
    local image="$REGISTRY/$IMAGE_NAME:$tag"
    local backend
    backend=$(detect_backend "$tag")

    echo ""
    info "image:   $image"
    info "backend: $(backend_label "$backend")"

    # Pull latest
    info "pulling latest..."
    $ENGINE pull "$image"

    # Build run command
    local flags
    flags=$(device_flags "$backend")

    # Container args (passed after the image name to override entrypoint defaults)
    local container_args=()
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        container_args=("--" "${EXTRA_ARGS[@]}")
    fi

    if $DRY_RUN; then
        echo ""
        info "dry-run: command that would be executed:"
        echo ""
        # shellcheck disable=SC2086
        echo "$ENGINE run --rm -it --network host $flags $image${container_args:+ ${container_args[*]}}"
        return 0
    fi

    echo ""
    info "starting thinkpod..."
    echo ""

    # shellcheck disable=SC2086
    exec $ENGINE run --rm -it \
        --network host \
        $flags \
        "$image" "${container_args[@]}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

ACTION=""
TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list|-l)
            ACTION="list"
            shift
            ;;
        --help|-h)
            ACTION="help"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --registry)
            [[ -z "${2:-}" ]] && die "--registry requires a value (e.g. --registry host/org)"
            REGISTRY="$2"
            shift 2
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
            TAG="$1"
            shift
            ;;
    esac
done

case "${ACTION:-}" in
    list)
        cmd_list
        ;;
    help)
        echo "Usage: ./run-remote.sh [OPTIONS] [TAG] [-- LLAMA_ARGS...]"
        echo ""
        echo "Pull and run a thinkpod container from an OCI registry."
        echo ""
        echo "Commands:"
        echo "  (no args)       Interactive: pick from available images"
        echo "  TAG             Run a specific tag directly"
        echo "  --list          List available images"
        echo "  --help          Show this help"
        echo ""
        echo "Options:"
        echo "  --dry-run            Print the run command without executing it"
        echo "  --registry HOST/ORG  Registry prefix (default: tendi.lan:4200/djkunkel)"
        echo ""
        echo "Passing llama-server args:"
        echo "  Anything after -- is forwarded verbatim to the container (overrides defaults)."
        echo "  Examples:"
        echo "    ./run-remote.sh TAG -- -c 8192"
        echo "    ./run-remote.sh TAG -- -c 32768 --temp 0.7 --top-p 0.9"
        echo ""
        echo "Environment:"
        echo "  REGISTRY    Registry prefix (default: tendi.lan:4200/djkunkel)"
        echo "  ENGINE      Container engine: podman or docker (auto-detected)"
        echo ""
        echo "First-time setup:"
        echo "  1. Configure insecure registry (if registry is plain HTTP):"
        echo "       echo '[[registry]]"
        echo "       location = \"tendi.lan:4200\""
        echo "       insecure = true' | sudo tee /etc/containers/registries.conf.d/tendi-gitea.conf"
        echo ""
        echo "  2. Login to the registry:"
        echo "       podman login tendi.lan:4200"
        ;;
    "")
        if [[ -n "$TAG" ]]; then
            cmd_direct "$TAG"
        else
            cmd_interactive
        fi
        ;;
esac
