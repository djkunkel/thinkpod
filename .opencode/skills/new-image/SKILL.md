---
name: new-image
description: Guide the user through finding a GGUF model on HuggingFace, researching recommended settings, creating a profile, and building a container image for one or more GPU backends (CUDA, ROCm, Vulkan).
---

# New Image Skill

You are helping the user create a self-contained llama-server container image
with a GGUF model baked in.  This is a multi-step interactive workflow.  Ask
questions along the way — do not guess or skip steps.

## High-level workflow

1. **Identify the model** — ask the user what they need or accept a HuggingFace
   repo name directly.
2. **Research the model** — fetch metadata from HuggingFace, inspect the model
   card, and determine recommended runtime settings.
3. **Create a profile** — write a `profiles/<name>.sh` file with the correct
   `REPO`, `FILES`, and `DEFAULTS` arrays.
4. **Build the image** — run `./build.sh --profile <name>` for one or more GPU
   backends, verifying each build succeeds.

Each step is described in detail below.

---

## Step 1 — Identify the model

Ask the user one of:

- What kind of model are you looking for?  (e.g. "a small reasoning model",
  "a 70B coding model", "a roleplay model around 12B")
- Or provide a HuggingFace repo name directly (e.g. `unsloth/Qwen3-8B-GGUF`).

If the user describes what they want rather than naming a repo:

1. Search HuggingFace (via web search) for GGUF quantized models that match
   the description.  Prefer repos from well-known quantizers: **unsloth**,
   **bartowski**, **mradermacher**, **QuantFactory**.
2. Present 2-4 candidate repos with a brief description of each (parameter
   count, architecture, specialization, context length).
3. Ask the user to pick one.

Once a repo is selected, confirm it with the user before proceeding.

---

## Step 2 — Research the model

Gather the following information:

### 2a. Model metadata

Fetch the model page from HuggingFace and extract:

- **Architecture** (e.g. llama, qwen2, mistral, gemma2, phi3)
- **Parameter count**
- **Maximum context length** (from config.json or model card)
- **Chat template** — does it contain `<think>` or `enable_thinking`?
  If yes, the model supports reasoning.
- **Vision / multimodal** — are there `mmproj*.gguf` files in the repo?
- **Available quantizations** — list the GGUF files and their sizes.

### 2b. Available GGUF files

List every `.gguf` file in the repo.  Separate them into:

- **Quantization files** (the main model weights)
- **Vision projector files** (`mmproj*.gguf`)

### 2c. Recommended settings

Research the model card and any linked papers/docs for the recommended
sampling and runtime settings.  Look for:

- **Recommended context size** — use the model card recommendation if present,
  otherwise cap at `131072` for models with context > 131072.
- **Temperature** — many model cards specify a recommended temp.
- **Top-K, Top-P, Min-P** — use model card values if present.
- **Repetition / presence penalty**
- **Reasoning budget** — for reasoning models, a sensible thinking token limit.

If the model card does not specify sampling settings, use these sensible
defaults based on the model type:

| Model type      | temp | top-k | top-p | presence-penalty | reasoning |
|-----------------|------|-------|-------|------------------|-----------|
| General / chat  | 1.0  | 20    | 0.95  | 1.5              | on / 4096 |
| Code            | 0.6  | 40    | 0.95  | 0.0              | on / 4096 |
| Roleplay / RP   | 0.8  | —     | —     | 1.05 (repeat)    | off       |
| Embedding / tool | 0.0 | —     | —     | 0.0              | off       |

Present your findings to the user in a clear summary and ask them to confirm
or adjust before creating the profile.

---

## Step 3 — Create a profile

### 3a. Choose quantization and vision projector

Ask the user which quantization to use.  Recommend **Q4_K_M** as the default
for most use cases.  Mention trade-offs:

- Q4_K_M — best balance of quality and VRAM
- Q5_K_M — slightly better quality, ~20% more VRAM
- Q6_K — near-lossless, significantly more VRAM
- Q8_0 — highest quality GGUF quant, most VRAM

If the model has mmproj files, ask whether to include vision support.  If yes,
recommend **mmproj-F16.gguf** (or whatever F16 variant exists).

### 3b. Choose profile name

Auto-generate a name from the repo: strip the `-GGUF` suffix, lowercase it.
For example: `unsloth/Qwen3-8B-GGUF` becomes `qwen3-8b`.  Confirm with the
user.

### 3c. Write the profile file

Write the profile to `profiles/<name>.sh` using this exact format:

```bash
# profiles/<name>.sh — <Model Label> (<quant tag>[  + vision])
#
# <One-line description of the model.>
# Architecture: <arch> | Max context: <ctx> | Reasoning: yes/no | Vision: yes/no

REPO="<org>/<Model-GGUF>"
FILES=("<model-quant>.gguf"[ "<mmproj>.gguf"])

# Runtime defaults — native llama-server flags.
# Baked into the image; overridable at `podman run` time via -- args.
DEFAULTS=(
    -c <context_size>
    -n <max_predict>
    -ngl 999
    --flash-attn on
    <sampling flags>
    --reasoning <on|off>
    [--reasoning-budget <N>]
)
```

Important rules for the profile:

- `FILES` is a **bash array** with parentheses and quoted elements.
- `DEFAULTS` is a **bash array**.  Flag-value pairs are adjacent elements
  (e.g. `-c 131072` is two elements: `-c` and `131072`).
- `-ngl 999` means "offload all layers to GPU" — always include this.
- `--flash-attn on` should always be included.
- Only include `--reasoning-budget` if reasoning is `on`.
- Use the native llama-server flag names (check `llama-server --help` if
  uncertain).

After writing the profile, show the user the file contents and ask for
confirmation.

---

## Step 4 — Build the image

### 4a. Ask which backends to build

Ask the user which GPU backend(s) they want.  The options are:

| Flag       | Backend                                  |
|------------|------------------------------------------|
| `--cuda`   | NVIDIA GPUs                              |
| `--rocm`   | AMD discrete GPUs                        |
| `--vulkan` | Vulkan (AMD iGPU, Intel, broad compat)   |

The user may want more than one.

### 4b. Build

For each selected backend, run:

```bash
./build.sh --profile <name> --<backend>
```

Monitor the build output.  If the build fails, diagnose the error and help the
user fix it.  Common issues:

- Missing model files in `models/` — re-run `./models.sh --profile <name>`
- Base image pull failure — check network / registry access
- `.containerignore` not whitelisting a needed file

### 4c. Verify the image

After each successful build, run these verification commands:

```bash
# Check defaults.conf was baked in correctly
podman run --rm --entrypoint cat <image_tag> /defaults.conf

# Check model files are in the right place
podman run --rm --entrypoint ls <image_tag> /root/.cache/huggingface/hub/
```

### 4d. Offer to push

If the build succeeds, ask if the user wants to push to the registry.  If yes:

```bash
./build.sh --profile <name> --<backend> --push
```

### 4e. Print the run command

After all builds complete, print the run commands for each backend.  Use the
device flags from AGENTS.md:

| Backend | Flags                                                                              |
|---------|------------------------------------------------------------------------------------|
| CUDA    | `--device nvidia.com/gpu=all --security-opt label=disable`                         |
| ROCm    | `--device /dev/kfd --device /dev/dri --security-opt seccomp=unconfined --security-opt label=disable` |
| Vulkan  | `--device /dev/dri --security-opt label=disable`                                   |

All run commands must include `--network host` (required due to a podman
rootless pasta bug with IPv6).

---

## Reference: existing profiles

Look at the existing profiles in `profiles/` for style and format reference.
The key files are:

- `profiles/qwen3.5-4b.sh` — vision + reasoning model
- `profiles/wayfarer-2-12b.sh` — roleplay model, no vision, no reasoning

## Reference: key scripts

- `build.sh` — orchestrates the full build pipeline
- `models.sh` — stages GGUF files from the HF cache into `models/`
- `new-profile.sh` — interactive profile generator (reference for format, but
  this skill replaces the interactive flow with a smarter guided process)
- `entrypoint.sh` — container entrypoint that merges defaults with user flags
