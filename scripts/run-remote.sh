#!/usr/bin/env bash
#
# Pull and run a llama-serve container image from the Gitea registry.
#
# Queries the registry for available images, presents an interactive menu,
# auto-detects the GPU backend from the tag, and runs with the correct
# device flags.
#
# Usage:
#   ./run-remote.sh                                # interactive: pick from registry
#   ./run-remote.sh qwen3.5-4b-q4_k_m-vulkan       # run a specific tag directly
#   ./run-remote.sh --list                         # just list available images
#
# First-time setup on the remote machine:
#   1. Configure insecure registry (if Gitea is plain HTTP):
#        echo '[[registry]]
#        location = "tendi.lan:4200"
#        insecure = true' | sudo tee /etc/containers/registries.conf.d/tendi-gitea.conf
#
#   2. Login to the registry:
#        podman login tendi.lan:4200
#
# Environment:
#   REGISTRY    Registry prefix (default: tendi.lan:4200/djkunkel)
#   ENGINE      Container engine: podman or docker (auto-detected)
#   GITEA_URL   Gitea API base URL (default: http://tendi.lan:4200)
#   GITEA_USER  Gitea username for API queries (default: djkunkel)

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────

REGISTRY="${REGISTRY:-tendi.lan:4200/djkunkel}"
GITEA_URL="${GITEA_URL:-http://tendi.lan:4200}"
GITEA_USER="${GITEA_USER:-djkunkel}"
IMAGE_NAME="llama-serve"
ENGINE="${ENGINE:-}"

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
        *-cuda)    echo "cuda" ;;
        *-vulkan)  echo "vulkan" ;;
        *)         echo "unknown" ;;
    esac
}

# Human-readable backend description
backend_label() {
    case "$1" in
        cuda)    echo "NVIDIA CUDA" ;;
        rocm)    echo "AMD ROCm (discrete GPU)" ;;
        vulkan)  echo "Vulkan (broad compatibility)" ;;
        *)       echo "unknown" ;;
    esac
}

# Print the podman/docker device flags for a backend
device_flags() {
    case "$1" in
        cuda)
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
    info "querying $GITEA_URL for available images..."
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
    info "querying $GITEA_URL for available images..."

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

    echo ""
    info "starting llama-serve..."
    echo ""

    # shellcheck disable=SC2086
    exec $ENGINE run --rm -it \
        --network host \
        $flags \
        "$image"
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    --list|-l)
        cmd_list
        ;;
    --help|-h)
        echo "Usage: ./run-remote.sh [OPTIONS] [TAG]"
        echo ""
        echo "Pull and run a llama-serve container from the Gitea registry."
        echo ""
        echo "Commands:"
        echo "  (no args)       Interactive: pick from available images"
        echo "  TAG             Run a specific tag directly"
        echo "  --list          List available images"
        echo "  --help          Show this help"
        echo ""
        echo "Environment:"
        echo "  REGISTRY    Registry prefix (default: tendi.lan:4200/djkunkel)"
        echo "  ENGINE      Container engine: podman or docker (auto-detected)"
        echo "  GITEA_URL   Gitea API URL (default: http://tendi.lan:4200)"
        echo "  GITEA_USER  Gitea username (default: djkunkel)"
        echo ""
        echo "First-time setup:"
        echo "  1. Configure insecure registry (plain HTTP Gitea):"
        echo "       echo '[[registry]]"
        echo "       location = \"tendi.lan:4200\""
        echo "       insecure = true' | sudo tee /etc/containers/registries.conf.d/tendi-gitea.conf"
        echo ""
        echo "  2. Login to the registry:"
        echo "       podman login tendi.lan:4200"
        ;;
    "")
        cmd_interactive
        ;;
    -*)
        die "unknown option: $1 (try --help)"
        ;;
    *)
        cmd_direct "$1"
        ;;
esac
