#!/usr/bin/env bash
#
# Interactive profile generator for thinkpod.
#
# Queries the HuggingFace Hub API for model metadata, then walks you through
# selecting a quantization, vision projector, context size, and other runtime
# defaults.  Writes a ready-to-use profile to profiles/<name>.sh.
#
# Usage:
#   ./new-profile.sh <repo>                     # e.g. unsloth/Qwen3.5-4B-GGUF
#   ./new-profile.sh <repo> --name <profile>    # explicit profile name
#
# Prerequisites:
#   - hf CLI (pip install huggingface_hub[cli])
#   - jq or python3 (for JSON parsing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles"

# ── Helpers ──────────────────────────────────────────────────────────────────

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# JSON field extractor — prefers jq, falls back to python3.
# Field uses jq syntax (e.g. '.gguf.architecture').
json_field() {
    local json="$1" field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r "$field // \"null\""
    elif command -v python3 &>/dev/null; then
        echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
path = sys.argv[1].lstrip('.').split('.')
val = d
for part in path:
    if isinstance(val, dict):
        val = val.get(part)
    else:
        val = None
    if val is None:
        break
print(val if val is not None else 'null')
" "$field"
    else
        die "neither jq nor python3 found — cannot parse JSON"
    fi
}

# Prompt the user with a default value.  Usage: prompt "Label" "default"
prompt() {
    local label="$1" default="$2" reply
    read -rp "$label [$default]: " reply
    echo "${reply:-$default}"
}

# Prompt with a yes/no default.  Usage: prompt_yn "Question" "Y"
prompt_yn() {
    local label="$1" default="$2" reply
    if [[ "$default" == "Y" ]]; then
        read -rp "$label [Y/n]: " reply
        reply="${reply:-Y}"
    else
        read -rp "$label [y/N]: " reply
        reply="${reply:-N}"
    fi
    [[ "$reply" =~ ^[Yy] ]]
}

# Prompt to pick from a numbered list.  Usage: pick_one "header" default_idx items...
# Prints the selected item to stdout.
pick_one() {
    local header="$1" default_idx="$2"
    shift 2
    local items=("$@")
    local count=${#items[@]}

    echo "" >&2
    echo "$header" >&2
    for i in "${!items[@]}"; do
        local num=$((i + 1))
        local marker=""
        if [[ $num -eq $default_idx ]]; then
            marker="  ← default"
        fi
        printf "  %2d) %s%s\n" "$num" "${items[$i]}" "$marker" >&2
    done
    echo "" >&2

    local choice
    read -rp "Select [${default_idx}]: " choice
    choice="${choice:-$default_idx}"

    # Validate
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then
        die "invalid selection: $choice"
    fi

    echo "${items[$((choice - 1))]}"
}

# ── Parse arguments ──────────────────────────────────────────────────────────

REPO=""
PROFILE_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)  PROFILE_NAME="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./new-profile.sh <repo> [--name <profile-name>]"
            echo ""
            echo "Interactively create a model profile for thinkpod."
            echo ""
            echo "Arguments:"
            echo "  <repo>              HuggingFace repo (e.g. unsloth/Qwen3.5-4B-GGUF)"
            echo ""
            echo "Options:"
            echo "  --name NAME         Profile name (default: auto-generated from repo)"
            echo "  --help              Show this help"
            echo ""
            echo "Prerequisites:"
            echo "  hf CLI              pip install huggingface_hub[cli]"
            echo "  jq or python3       For JSON parsing"
            exit 0
            ;;
        -*)
            die "unknown option: $1 (try --help)"
            ;;
        *)
            if [[ -z "$REPO" ]]; then
                REPO="$1"
            else
                die "unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$REPO" ]]; then
    die "usage: ./new-profile.sh <repo> (e.g. unsloth/Qwen3.5-4B-GGUF)"
fi

# ── Check prerequisites ─────────────────────────────────────────────────────

if ! command -v hf &>/dev/null; then
    die "hf CLI not found. Install it: pip install huggingface_hub[cli]"
fi

if ! command -v jq &>/dev/null && ! command -v python3 &>/dev/null; then
    die "neither jq nor python3 found — need one for JSON parsing"
fi

# ── Fetch model info ─────────────────────────────────────────────────────────

info "fetching model info for $REPO..."
echo ""

MODEL_JSON=$(hf models info "$REPO" --expand siblings,gguf --format json 2>&1) \
    || die "failed to fetch model info for $REPO — is the repo name correct?"

# ── Extract metadata ─────────────────────────────────────────────────────────

ARCH=$(json_field "$MODEL_JSON" '.gguf.architecture')
CTX_MAX=$(json_field "$MODEL_JSON" '.gguf.context_length')
CHAT_TEMPLATE=$(json_field "$MODEL_JSON" '.gguf.chat_template')

# Get all filenames from siblings
ALL_FILES=()
while IFS= read -r f; do
    [[ -n "$f" ]] && ALL_FILES+=("$f")
done < <(
    if command -v jq &>/dev/null; then
        echo "$MODEL_JSON" | jq -r '.siblings[].rfilename'
    else
        echo "$MODEL_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('siblings', []):
    print(s.get('rfilename', ''))
"
    fi
)

# Separate into categories
QUANT_FILES=()
MMPROJ_FILES=()
for f in "${ALL_FILES[@]}"; do
    case "$f" in
        mmproj*.gguf) MMPROJ_FILES+=("$f") ;;
        *.gguf)       QUANT_FILES+=("$f") ;;
    esac
done

# Detect features
HAS_VISION=false
if [[ ${#MMPROJ_FILES[@]} -gt 0 ]]; then
    HAS_VISION=true
fi

HAS_REASONING=false
if [[ "$CHAT_TEMPLATE" == *"<think>"* ]] || [[ "$CHAT_TEMPLATE" == *"enable_thinking"* ]]; then
    HAS_REASONING=true
fi

# ── Display summary ──────────────────────────────────────────────────────────

echo "  Model:        $REPO"
echo "  Architecture: ${ARCH:-unknown}"
echo "  Max context:  ${CTX_MAX:-unknown} tokens"
echo "  Vision:       $($HAS_VISION && echo "yes (${#MMPROJ_FILES[@]} mmproj file(s))" || echo "no")"
echo "  Reasoning:    $($HAS_REASONING && echo "yes" || echo "no")"

# ── Check we have quantizations ──────────────────────────────────────────────

if [[ ${#QUANT_FILES[@]} -eq 0 ]]; then
    die "no GGUF quantization files found in $REPO"
fi

# ── Select quantization ─────────────────────────────────────────────────────

# Find the default (Q4_K_M if available, otherwise first)
DEFAULT_QUANT_IDX=1
for i in "${!QUANT_FILES[@]}"; do
    if [[ "${QUANT_FILES[$i]}" == *Q4_K_M* ]]; then
        DEFAULT_QUANT_IDX=$((i + 1))
        break
    fi
done

SELECTED_QUANT=$(pick_one "Available quantizations:" "$DEFAULT_QUANT_IDX" "${QUANT_FILES[@]}")

# ── Select vision projector (if applicable) ──────────────────────────────────

SELECTED_MMPROJ=""
if $HAS_VISION; then
    if prompt_yn "Vision model detected. Include vision support?" "Y"; then
        # Find default (F16 preferred)
        DEFAULT_MMPROJ_IDX=1
        for i in "${!MMPROJ_FILES[@]}"; do
            if [[ "${MMPROJ_FILES[$i]}" == *F16* ]]; then
                DEFAULT_MMPROJ_IDX=$((i + 1))
                break
            fi
        done

        SELECTED_MMPROJ=$(pick_one "Available vision projectors:" "$DEFAULT_MMPROJ_IDX" "${MMPROJ_FILES[@]}")
    fi
fi

# ── Configure runtime defaults ───────────────────────────────────────────────

echo ""
info "runtime defaults (baked into image, overridable at run time)"
echo ""

# Context size — suggest a reasonable cap
if [[ "$CTX_MAX" =~ ^[0-9]+$ ]] && (( CTX_MAX > 131072 )); then
    DEFAULT_CTX=131072
elif [[ "$CTX_MAX" =~ ^[0-9]+$ ]]; then
    DEFAULT_CTX="$CTX_MAX"
else
    DEFAULT_CTX=8192
fi
CTX_SIZE=$(prompt "Context size (model max: ${CTX_MAX:-unknown})" "$DEFAULT_CTX")

N_PREDICT=$(prompt "Max tokens to predict" "32768")
N_GPU_LAYERS=$(prompt "GPU layers" "999")

# Reasoning
REASONING_ON="off"
REASONING_BUDGET="4096"
if $HAS_REASONING; then
    if prompt_yn "Enable reasoning (thinking)?" "Y"; then
        REASONING_ON="on"
        REASONING_BUDGET=$(prompt "Reasoning budget (tokens)" "4096")
    fi
fi

# ── Generate profile name ───────────────────────────────────────────────────

if [[ -z "$PROFILE_NAME" ]]; then
    # unsloth/Qwen3.5-4B-GGUF → qwen3.5-4b
    auto_name="${REPO##*/}"            # Qwen3.5-4B-GGUF
    auto_name="${auto_name%-GGUF}"     # Qwen3.5-4B
    auto_name="${auto_name,,}"         # qwen3.5-4b (lowercase)
    PROFILE_NAME=$(prompt "Profile name" "$auto_name")
fi

# ── Confirm & write ─────────────────────────────────────────────────────────

PROFILE_FILE="$PROFILES_DIR/$PROFILE_NAME.sh"
mkdir -p "$PROFILES_DIR"

if [[ -f "$PROFILE_FILE" ]]; then
    if ! prompt_yn "Profile '$PROFILE_NAME' already exists. Overwrite?" "N"; then
        echo "Aborted."
        exit 0
    fi
fi

# Build FILES array string
FILES_STR="\"$SELECTED_QUANT\""
if [[ -n "$SELECTED_MMPROJ" ]]; then
    FILES_STR="\"$SELECTED_QUANT\" \"$SELECTED_MMPROJ\""
fi

# Build description parts
DESC_PARTS=""
if [[ -n "$SELECTED_MMPROJ" ]]; then
    # Extract quant tag: Qwen3.5-4B-Q4_K_M.gguf → Q4_K_M
    quant_tag=""
    if [[ "$SELECTED_QUANT" =~ [-_](Q[0-9A-Za-z_]+)\. ]]; then
        quant_tag="${BASH_REMATCH[1]}"
    elif [[ "$SELECTED_QUANT" =~ [-_](BF16|F16|F32)\. ]]; then
        quant_tag="${BASH_REMATCH[1]}"
    fi
    DESC_PARTS="${quant_tag:+$quant_tag + }vision"
else
    quant_tag=""
    if [[ "$SELECTED_QUANT" =~ [-_](Q[0-9A-Za-z_]+)\. ]]; then
        quant_tag="${BASH_REMATCH[1]}"
    elif [[ "$SELECTED_QUANT" =~ [-_](BF16|F16|F32)\. ]]; then
        quant_tag="${BASH_REMATCH[1]}"
    fi
    DESC_PARTS="${quant_tag:-unknown quant}"
fi

# Friendly model name from repo
MODEL_LABEL="${REPO##*/}"
MODEL_LABEL="${MODEL_LABEL%-GGUF}"

cat > "$PROFILE_FILE" <<EOF
# profiles/${PROFILE_NAME}.sh — ${MODEL_LABEL} (${DESC_PARTS})
#
# Generated by new-profile.sh on $(date -I)
# Architecture: ${ARCH:-unknown} | Max context: ${CTX_MAX:-unknown} | Reasoning: $($HAS_REASONING && echo "yes" || echo "no") | Vision: $($HAS_VISION && echo "yes" || echo "no")

REPO="$REPO"
FILES=($FILES_STR)

# Runtime defaults — native llama-server flags.
# Baked into the image; overridable at \`podman run\` time via -- args.
DEFAULTS=(
    -c $CTX_SIZE
    -n $N_PREDICT
    -ngl $N_GPU_LAYERS
    --flash-attn on
    --temp 1.0
    --top-k 20
    --top-p 0.95
    --presence-penalty 1.5
    --reasoning $REASONING_ON
    --reasoning-budget $REASONING_BUDGET
)
EOF

echo ""
info "wrote $PROFILE_FILE"
echo ""
echo "Next steps:"
echo "  ./build.sh --profile $PROFILE_NAME --cuda    # NVIDIA"
echo "  ./build.sh --profile $PROFILE_NAME --rocm    # AMD"
echo "  ./build.sh --profile $PROFILE_NAME --vulkan  # Vulkan"
