#!/usr/bin/env bash
#
# Manage llama-server backends for run.sh.
#
# Binary backends (cpu, rocm, rocm-nightly, vulkan) are downloaded as
# llama.cpp release tarballs/zip and cached under bin/. Container backends
# (cuda, cuda12) are pulled as ghcr.io images via podman/docker.
#
# A gitignored state file at bin/current records the currently selected
# build/image per backend. run.sh reads it via `backends.sh current` and
# never downloads anything itself; if no selection exists it falls back to
# the newest cached build, and if none are cached it calls
# `backends.sh update` to fetch one.
#
# Usage:
#   ./backends.sh update  --<backend> [--release TAG] [--dry-run] [--no-mark]
#   ./backends.sh use     --<backend> --release TAG
#   ./backends.sh list    [--<backend>]
#   ./backends.sh prune   [--<backend>] [--keep N] [--dry-run]
#   ./backends.sh current --<backend> [--release TAG]
#
# Subcommands:
#   update   Download the latest (or --release TAG) build and mark it current.
#            For container backends this pulls the image. --no-mark downloads
#            without changing bin/current (used by run.sh for one-off runs).
#   use      Mark an already-cached build as current (no download).
#            Binary backends only.
#   list     Show cached builds/images and the current selection.
#   prune    Delete non-current cached builds (binary) and dangling images
#            (container). --keep N preserves the N newest per binary backend.
#   current  Print the current cache dir (binary) or image ref (container)
#            for run.sh to consume. Exits 1 if a binary backend has no
#            cached build so run.sh can trigger an update. With --release
#            TAG, requires that exact build to be cached (else exit 1).
#
# Backends:
#   --cpu           Ubuntu x64 CPU-only build (upstream llama.cpp release)
#   --rocm          Ubuntu x64 ROCm build     (upstream llama.cpp release)
#   --rocm-nightly  Ubuntu x64 ROCm build     (lemonade-sdk/llamacpp-rocm nightly)
#   --vulkan        Ubuntu x64 Vulkan build   (upstream llama.cpp release)
#   --cuda          NVIDIA CUDA 13 (ghcr.io container image)
#   --cuda12        NVIDIA CUDA 12 (ghcr.io container image)
#
# Environment:
#   LLAMA_RELEASE       Pin release tag (same as --release)
#   ROCM_VERSION        ROCm version in asset name (default: 10.0)
#   ROCM_NIGHTLY_REPO   GitHub repo for nightly ROCm builds
#                       (default: lemonade-sdk/llamacpp-rocm)
#   ROCM_GFX            GPU target for nightly builds (default: gfx120X)
#   ARCH                CPU architecture override (default: x64)
#   ENGINE              Container engine: podman or docker (auto-detected)
#
# Cache layout (binary):
#   bin/<backend>/<tag>/           — cpu, rocm, vulkan
#   bin/rocm-nightly/<tag>-<gfx>/  — rocm-nightly
# State file (gitignored, lives under bin/):
#   bin/current   lines of `<backend>=<value>` where value is the cache
#                 subdir name (binary) or image ref (container).

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

ROCM_VERSION="${ROCM_VERSION:-10.0}"
ROCM_NIGHTLY_REPO="${ROCM_NIGHTLY_REPO:-lemonade-sdk/llamacpp-rocm}"
ROCM_GFX="${ROCM_GFX:-gfx120X}"
ARCH="${ARCH:-x64}"
ENGINE="${ENGINE:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
STATE_FILE="$BIN_DIR/current"

ALL_BACKENDS=(cpu rocm rocm-nightly vulkan cuda cuda12)
BINARY_BACKENDS=(cpu rocm rocm-nightly vulkan)
CONTAINER_BACKENDS=(cuda cuda12)

# ── Helpers ───────────────────────────────────────────────────────────────────

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

_is_container() {
    [[ "$1" == "cuda" || "$1" == "cuda12" ]]
}

_valid_backend() {
    local b
    for b in "${ALL_BACKENDS[@]}"; do [[ "$b" == "$1" ]] && return 0; done
    return 1
}

# Resolve the latest release tag for a binary backend from a GitHub repo.
# Scans recent releases and picks the newest one that actually ships the
# backend's asset: upstream llama.cpp now marks its `b*` build releases as
# pre-releases, so /releases/latest points at a source-only tag (e.g. v0.5.0)
# with no binaries.
# $1 = backend, $2 = repo in "owner/name" form. Prints the tag or empty string.
_resolve_latest_release() {
    local backend="$1" repo="$2" json tag asset
    json="$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/${repo}/releases?per_page=30" \
        2>/dev/null || true)"
    [[ -z "$json" ]] && return 0
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        asset="$(asset_name "$backend" "$tag")"
        [[ -z "$asset" ]] && continue
        if grep -qF "\"name\": \"${asset}\"" <<<"$json"; then
            echo "$tag"
            return 0
        fi
    done < <(grep '"tag_name"' <<<"$json" | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
}

# GitHub repo that hosts releases for a backend.
backend_repo() {
    [[ "$1" == "rocm-nightly" ]] && echo "${ROCM_NIGHTLY_REPO}" || echo "ggml-org/llama.cpp"
}

# Asset filename on GitHub releases for a binary backend + tag.
# $1 = backend, $2 = tag
asset_name() {
    local backend="$1" tag="$2"
    case "$backend" in
        cpu)          echo "llama-${tag}-bin-ubuntu-${ARCH}.tar.gz" ;;
        vulkan)       echo "llama-${tag}-bin-ubuntu-vulkan-${ARCH}.tar.gz" ;;
        rocm)         echo "llama-${tag}-bin-ubuntu-rocm-${ROCM_VERSION}-${ARCH}.tar.gz" ;;
        rocm-nightly) echo "llama-${tag}-ubuntu-rocm-${ROCM_GFX}-${ARCH}.zip" ;;
    esac
}

backend_label() {
    case "$1" in
        cpu)          echo "CPU (Ubuntu x64)" ;;
        rocm)         echo "AMD ROCm ${ROCM_VERSION}" ;;
        rocm-nightly) echo "AMD ROCm nightly (${ROCM_GFX})" ;;
        vulkan)       echo "Vulkan" ;;
        cuda)         echo "NVIDIA CUDA 13 (container)" ;;
        cuda12)       echo "NVIDIA CUDA 12 (container)" ;;
    esac
}

default_image() {
    case "$1" in
        cuda)   echo "ghcr.io/ggml-org/llama.cpp:server-cuda13" ;;
        cuda12) echo "ghcr.io/ggml-org/llama.cpp:server-cuda"   ;;
    esac
}

# Cache search dir for a binary backend.
_search_dir() {
    if [[ "$1" == "rocm-nightly" ]]; then
        echo "$BIN_DIR/rocm-nightly"
    else
        echo "$BIN_DIR/$1"
    fi
}

# Cache subdir name for a backend + tag (rocm-nightly appends the gfx target).
_subdir_for_tag() {
    local backend="$1" tag="$2"
    if [[ "$backend" == "rocm-nightly" ]]; then
        echo "${tag}-${ROCM_GFX}"
    else
        echo "$tag"
    fi
}

# Convert a cache subdir name to the display tag (strip gfx suffix for nightly).
_subdir_to_tag() {
    if [[ "$1" == "rocm-nightly" ]]; then
        echo "${2%-$ROCM_GFX}"
    else
        echo "$2"
    fi
}

# Find the newest cached build subdir for a binary backend.
# Prints the subdir name (entry under the search dir) or empty if none cached.
# Only directories containing an executable llama-server are considered.
_latest_cached_subdir() {
    local backend="$1" search_dir
    search_dir="$(_search_dir "$backend")"
    [[ -d "$search_dir" ]] || return 0

    local entry candidates=() sorted
    while IFS= read -r entry; do
        [[ -x "$search_dir/$entry/llama-server" ]] || continue
        if [[ "$backend" == "rocm-nightly" ]]; then
            [[ "$entry" == *-"$ROCM_GFX" ]] || continue
        fi
        candidates+=("$entry")
    done < <(ls -1 "$search_dir" 2>/dev/null)

    (( ${#candidates[@]} > 0 )) || return 0
    sorted=$(printf '%s\n' "${candidates[@]}" | sort -Vr)
    echo "${sorted%%$'\n'*}"
}

# ── State file (bin/current) ──────────────────────────────────────────────────
# Lines of `<backend>=<value>`. Binary value = cache subdir name; container
# value = image ref. Missing file or missing key yields empty.

_state_read() {  # $1 = backend -> prints value or empty
    [[ -f "$STATE_FILE" ]] || return 0
    grep -E "^${1}=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
}

_state_write() {  # $1 = backend, $2 = value
    mkdir -p "$BIN_DIR"
    if [[ -f "$STATE_FILE" ]] && grep -qE "^${1}=" "$STATE_FILE" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        awk -v b="$1" -v v="$2" 'BEGIN{FS=OFS="="} $1==b{$2=v} {print}' "$STATE_FILE" > "$tmp"
        mv "$tmp" "$STATE_FILE"
    else
        echo "${1}=${2}" >> "$STATE_FILE"
    fi
}

# ── Container engine ──────────────────────────────────────────────────────────

# Detect a container engine into $ENGINE, returning non-zero (without exiting)
# if none is available. Used by query paths (list/prune) that must not abort
# on engine-less hosts.
_try_engine() {
    if [[ -n "$ENGINE" ]]; then
        command -v "$ENGINE" &>/dev/null && return 0 || return 1
    fi
    if command -v podman &>/dev/null; then
        ENGINE="podman"
    elif command -v docker &>/dev/null; then
        ENGINE="docker"
    else
        return 1
    fi
}

# Like _try_engine but fatal — for paths that genuinely require an engine
# (e.g. pulling an image).
_detect_engine() {
    _try_engine || die "neither podman nor docker found"
}

# ── Subcommands ───────────────────────────────────────────────────────────────

# current --backend NAME [--release TAG]
# Binary: print absolute cache dir path. With --release, require that exact
#   build to be cached (else exit 1). Without it, use the state file, falling
#   back to the newest cached build. Exit 1 if nothing is cached.
# Container: print image ref (state file, else default). Always exit 0.
cmd_current() {
    local backend="$1" release="${2:-}"

    if _is_container "$backend"; then
        local img
        img="$(_state_read "$backend")"
        [[ -z "$img" ]] && img="$(default_image "$backend")"
        echo "$img"
        return 0
    fi

    local search_dir subdir
    search_dir="$(_search_dir "$backend")"

    if [[ -n "$release" ]]; then
        subdir="$(_subdir_for_tag "$backend" "$release")"
        [[ -x "$search_dir/$subdir/llama-server" ]] && { echo "$search_dir/$subdir"; return 0; }
        return 1
    fi

    subdir="$(_state_read "$backend")"
    if [[ -n "$subdir" && -x "$search_dir/$subdir/llama-server" ]]; then
        echo "$search_dir/$subdir"
        return 0
    fi

    subdir="$(_latest_cached_subdir "$backend")"
    if [[ -n "$subdir" ]]; then
        echo "$search_dir/$subdir"
        return 0
    fi
    return 1
}

# update --backend NAME [--release TAG] [--dry-run] [--no-mark]
# When no_mark is true the build is downloaded but bin/current is left
# untouched (used by run.sh for one-off --release runs).
cmd_update() {
    local backend="$1" release="${2:-}" dry_run="${3:-false}" no_mark="${4:-false}"

    if _is_container "$backend"; then
        _detect_engine
        local img
        img="$(_state_read "$backend")"
        [[ -z "$img" ]] && img="$(default_image "$backend")"
        info "pulling image: $img"
        if ! $dry_run; then
            "$ENGINE" pull "$img" || die "image pull failed: $img"
            if ! $no_mark; then
                _state_write "$backend" "$img"
                info "current: $backend=$img"
            fi
        else
            info "dry-run: skip pull"
        fi
        return 0
    fi

    # Binary backend.
    local tag="$release"
    if [[ -z "$tag" ]]; then
        tag="$(_resolve_latest_release "$backend" "$(backend_repo "$backend")")"
    fi
    [[ -z "$tag" ]] && die "could not resolve release tag from GitHub API — check your network or pin with --release"

    local search_dir subdir cache_dir asset url
    search_dir="$(_search_dir "$backend")"
    subdir="$(_subdir_for_tag "$backend" "$tag")"
    cache_dir="$search_dir/$subdir"
    asset="$(asset_name "$backend" "$tag")"
    url="https://github.com/$(backend_repo "$backend")/releases/download/${tag}/${asset}"

    if [[ -x "$cache_dir/llama-server" ]]; then
        info "already cached: $cache_dir"
    else
        info "downloading ${tag} ${backend} build"
        info "source: $url"
        if $dry_run; then
            info "dry-run: skip download"
            return 0
        fi
        command -v curl &>/dev/null || die "curl is required"
        command -v tar  &>/dev/null || die "tar is required"
        [[ "$backend" == "rocm-nightly" ]] && { command -v unzip &>/dev/null || die "unzip is required for --rocm-nightly"; }

        mkdir -p "$cache_dir"
        local tmpfile
        case "$backend" in
            rocm-nightly) tmpfile="$(mktemp --suffix=.zip)" ;;
            *)            tmpfile="$(mktemp --suffix=.tar.gz)" ;;
        esac
        trap 'rm -f "${tmpfile:-}"' EXIT

        if ! curl -fL --progress-bar -o "$tmpfile" "$url"; then
            rm -rf "$cache_dir"
            die "download failed: $url"
        fi

        info "extracting to $cache_dir"
        case "$backend" in
            rocm-nightly)
                unzip -q -o "$tmpfile" -d "$cache_dir"
                for bin in "$cache_dir"/llama-*; do
                    [[ -f "$bin" ]] && chmod +x "$bin"
                done
                ;;
            *)
                tar -xzf "$tmpfile" -C "$cache_dir" --strip-components=1
                ;;
        esac

        [[ ! -x "$cache_dir/llama-server" ]] && die "extraction succeeded but llama-server not found at $cache_dir/llama-server"
        info "cached at $cache_dir"
    fi

    if ! $dry_run && ! $no_mark; then
        _state_write "$backend" "$subdir"
        info "current: $backend=$subdir"
    fi
}

# use --backend NAME --release TAG   (binary backends only)
cmd_use() {
    local backend="$1" release="$2"
    _is_container "$backend" && die "use is for binary backends; containers select via image ref"

    local search_dir subdir
    search_dir="$(_search_dir "$backend")"
    subdir="$(_subdir_for_tag "$backend" "$release")"
    [[ -x "$search_dir/$subdir/llama-server" ]] \
        || die "no cached build for $backend at tag $release (run 'backends.sh update --$backend --release $release' to download)"
    _state_write "$backend" "$subdir"
    info "current: $backend=$subdir"
}

# list [--backend NAME]
cmd_list() {
    local filter="${1:-}"
    local b search_dir current_subdir entry tag has_any

    for b in "${BINARY_BACKENDS[@]}"; do
        [[ -n "$filter" && "$filter" != "$b" ]] && continue
        echo "$b ($(backend_label "$b")):"
        search_dir="$(_search_dir "$b")"
        current_subdir="$(_state_read "$b")"
        if [[ ! -d "$search_dir" ]]; then
            echo "    (no cached builds)"
            continue
        fi
        has_any=false
        while IFS= read -r entry; do
            [[ -d "$search_dir/$entry" ]] || continue
            has_any=true
            tag="$(_subdir_to_tag "$b" "$entry")"
            if [[ "$entry" == "$current_subdir" ]]; then
                echo "    $tag  (current)"
            else
                echo "    $tag"
            fi
        done < <(ls -1 "$search_dir" 2>/dev/null | sort -Vr)
        $has_any || echo "    (no cached builds)"
    done

    # Container backends: only attempt engine listing if one is available.
    local have_engine=false
    if _try_engine; then
        have_engine=true
    fi

    for b in "${CONTAINER_BACKENDS[@]}"; do
        [[ -n "$filter" && "$filter" != "$b" ]] && continue
        echo "$b ($(backend_label "$b")):"
        local current_img
        current_img="$(_state_read "$b")"
        [[ -z "$current_img" ]] && current_img="$(default_image "$b")"
        echo "    current image: $current_img"
        if $have_engine; then
            # Show locally pulled images matching this backend's default
            # image tag, so each backend only lists its own images.
            local img_tag
            img_tag="$(default_image "$b")"
            img_tag="${img_tag##*:}"
            "$ENGINE" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
                | grep -E ":${img_tag}\$" | sed 's/^/    /' || true
        fi
    done
}

# prune [--backend NAME] [--keep N] [--dry-run]
cmd_prune() {
    local filter="${1:-}" keep="${2:-0}" dry_run="${3:-false}"
    local b search_dir current_subdir entry i removed

    for b in "${BINARY_BACKENDS[@]}"; do
        [[ -n "$filter" && "$filter" != "$b" ]] && continue
        search_dir="$(_search_dir "$b")"
        [[ -d "$search_dir" ]] || continue
        current_subdir="$(_state_read "$b")"

        local dirs=()
        while IFS= read -r entry; do
            [[ -d "$search_dir/$entry" ]] && dirs+=("$entry")
        done < <(ls -1 "$search_dir" 2>/dev/null | sort -Vr)
        (( ${#dirs[@]} > 0 )) || continue

        i=0; removed=0
        for entry in "${dirs[@]}"; do
            i=$((i+1))
            (( keep > 0 && i <= keep )) && continue
            [[ "$entry" == "$current_subdir" ]] && continue
            if $dry_run; then
                echo "would remove: $search_dir/$entry"
            else
                rm -rf "$search_dir/$entry"
                info "removed: $search_dir/$entry"
            fi
            removed=$((removed+1))
        done
        (( removed == 0 )) && echo "$b: nothing to prune"
    done

    # Container backends: prune dangling images via the engine.
    if [[ -z "$filter" || "$filter" == "cuda" || "$filter" == "cuda12" ]]; then
        if _try_engine; then
            if $dry_run; then
                echo "would run: $ENGINE image prune -f"
            else
                "$ENGINE" image prune -f || true
            fi
        fi
    fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────

CMD=""
BACKEND=""
RELEASE=""
KEEP=0
DRY_RUN=false
NO_MARK=false

show_help() {
    sed -n '3,/^set -euo pipefail$/p' "$0" | sed 's/^# \{0,1\}//' | sed '/^set -euo pipefail$/d'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        update|use|list|prune|current) CMD="$1"; shift ;;
        --cpu)          BACKEND="cpu";          shift ;;
        --rocm)         BACKEND="rocm";         shift ;;
        --rocm-nightly) BACKEND="rocm-nightly"; shift ;;
        --vulkan)       BACKEND="vulkan";       shift ;;
        --cuda)         BACKEND="cuda";         shift ;;
        --cuda12)       BACKEND="cuda12";       shift ;;
        --backend)
            [[ -z "${2:-}" ]] && die "--backend requires a name"
            BACKEND="$2"; shift 2 ;;
        --release)
            [[ -z "${2:-}" ]] && die "--release requires a tag (e.g. --release b9785)"
            RELEASE="$2"; shift 2 ;;
        --keep)
            [[ -z "${2:-}" ]] && die "--keep requires a number"
            KEEP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --no-mark) NO_MARK=true; shift ;;
        --help|-h) show_help; exit 0 ;;
        -*)  die "unknown option: $1 (try --help)" ;;
        *)   die "unexpected argument: $1 (try --help)" ;;
    esac
done

[[ -z "$CMD" ]] && die "a subcommand is required (try --help)"

# list/prune accept an optional backend filter; others require a backend.
if [[ "$CMD" != "list" && "$CMD" != "prune" ]]; then
    [[ -z "$BACKEND" ]] && die "a backend is required (try --help)"
fi
if [[ -n "$BACKEND" ]] && ! _valid_backend "$BACKEND"; then
    die "unknown backend: $BACKEND"
fi

case "$CMD" in
    current) cmd_current "$BACKEND" "$RELEASE" ;;
    update)  cmd_update  "$BACKEND" "$RELEASE" "$DRY_RUN" "$NO_MARK" ;;
    use)     [[ -z "$RELEASE" ]] && die "use requires --release TAG"
             cmd_use "$BACKEND" "$RELEASE" ;;
    list)    cmd_list "$BACKEND" ;;
    prune)   cmd_prune "$BACKEND" "$KEEP" "$DRY_RUN" ;;
    *)       die "unknown subcommand: $CMD" ;;
esac
