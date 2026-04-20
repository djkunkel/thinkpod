#!/usr/bin/env bash
#
# Container entrypoint for llama-server.
#
# Runtime defaults are read from /defaults.conf (baked in at build time from
# the model profile).  Any flag passed after "--" in the podman/docker run
# command overrides the corresponding default.
#
#   podman run ... $IMAGE                          # all defaults
#   podman run ... $IMAGE -- -c 8192               # override context size
#   podman run ... $IMAGE -- --reasoning off        # disable reasoning
#
# The entrypoint handles smart merging: if you pass a flag that conflicts
# with a default, only your version is used (no duplicates).

set -euo pipefail

# ── Source build-time environment (e.g. HSA_OVERRIDE_GFX_VERSION) ────────────

if [[ -f /etc/environment ]]; then
    set -a
    # shellcheck source=/dev/null
    source /etc/environment
    set +a
fi

# ── Model (patched at build time by Containerfile) ───────────────────────────

HF_MODEL="__DEFAULT_MODEL__"

# ── Read defaults from /defaults.conf ────────────────────────────────────────

# Each line is a flag group: "-c 131072" or "--flash-attn on"
# Lines starting with # are comments.
default_flags=()
default_flag_names=()

if [[ -f /defaults.conf ]]; then
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Extract the flag name (first token)
        flag_name="${line%% *}"
        default_flags+=("$line")
        default_flag_names+=("$flag_name")
    done < /defaults.conf
fi

# ── Parse user-supplied flags from $@ ────────────────────────────────────────

# Strip the leading "--" sentinel that docker/podman passes when the user
# separates image args: `podman run IMAGE -- --flag`.  Without this, the
# literal "--" would be forwarded to llama-server as a stray argument.
if [[ "${1:-}" == "--" ]]; then
    shift
fi

# Collect all flag names the user passed so we can skip those defaults.
user_flag_names=()
for arg in "$@"; do
    if [[ "$arg" == -* ]]; then
        user_flag_names+=("$arg")
    fi
done

# ── Build the final argument list ────────────────────────────────────────────

# Infrastructure flags — always present (container needs these)
args=(
    -hf "$HF_MODEL"
    --offline
    --host 0.0.0.0
    --port 8080
    --metrics
)

# Add defaults, skipping any that the user overrode
for i in "${!default_flags[@]}"; do
    flag_name="${default_flag_names[$i]}"

    # Check if user supplied this flag
    skip=false
    for uf in "${user_flag_names[@]}"; do
        if [[ "$uf" == "$flag_name" ]]; then
            skip=true
            break
        fi
    done

    if ! $skip; then
        # Parse the line back into flag + value(s), respecting shell quoting
        # so that values with spaces (e.g. --reasoning-budget-message) survive.
        eval "args+=(${default_flags[$i]})"
    fi
done

# Append user flags last
if [[ $# -gt 0 ]]; then
    args+=("$@")
fi

# ── Print banner ─────────────────────────────────────────────────────────────

echo "Model:    $HF_MODEL"
echo "Endpoint: http://localhost:8080"

# Show key settings from the final args
for i in "${!args[@]}"; do
    case "${args[$i]}" in
        -c|--ctx-size)   echo "Context:  ${args[$((i+1))]:-(unset)}" ;;
        --flash-attn)   echo "Flash:    ${args[$((i+1))]:-(unset)}" ;;
        --reasoning)    echo "Reason:   ${args[$((i+1))]:-(unset)}" ;;
    esac
done

if [[ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]]; then
    echo "HSA GFX:  $HSA_OVERRIDE_GFX_VERSION"
fi

if [[ $# -gt 0 ]]; then
    echo "Overrides: $*"
fi
echo ""

# ── Run ──────────────────────────────────────────────────────────────────────

# The upstream llama.cpp image places the binary at /app/llama-server.
# Try the PATH first, fall back to /app/llama-server.
if command -v llama-server &>/dev/null; then
    exec llama-server "${args[@]}"
else
    exec /app/llama-server "${args[@]}"
fi
