---
name: new-profile
description: Guide the user through finding a GGUF model on HuggingFace, researching recommended settings, and creating a profile for use with run.sh.
---

# New Profile Skill

You are helping the user create a thinkpod profile for a GGUF model.  This is
a multi-step interactive workflow.  Ask questions along the way — do not guess
or skip steps.

## High-level workflow

1. **Identify the model** — ask the user what they need or accept a HuggingFace
   repo name directly.
2. **Research the model** — fetch metadata from HuggingFace, inspect the model
   card, and determine recommended runtime settings.
3. **Create a profile** — write a `profiles/<name>.sh` file with the correct
   `REPO`, `FILES`, and `DEFAULTS` arrays.
4. **Show how to run it** — print the correct `run.sh` command for the user's hardware.

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

### 3a. Choose quantization (note vision support)

Ask the user which quantization to use.  Recommend **Q4_K_M** as the default
for most use cases.  Mention trade-offs:

- Q4_K_M — best balance of quality and VRAM
- Q5_K_M — slightly better quality, ~20% more VRAM
- Q6_K — near-lossless, significantly more VRAM
- Q8_0 — highest quality GGUF quant, most VRAM

If the model has mmproj files, note `Vision: yes` in the profile header.
Do **not** add the projector to `FILES` — llama-server auto-downloads and
loads it from the `-hf` repo (disable at run time with `-- --no-mmproj`).

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
FILES=("<model-quant>.gguf")

# Runtime defaults — native llama-server flags.
# Passed directly to llama-server; overridable at run time via -- args.
DEFAULTS=(
    --n-predict <max_predict>
    --n-gpu-layers 999
    --flash-attn on
    <sampling flags>
    --reasoning <on|off>
    [--reasoning-budget <N>]
    [--reasoning-budget-message $'\n\nOkay, I need to stop thinking and give my response now.\n']
)
```

Important rules for the profile:

- `FILES` is a **bash array** with parentheses and quoted elements. Use it for
  the primary GGUF file(s) only; `run.sh` passes the first entry as `--hf-file`.
  The vision projector and MTP head are auto-downloaded by llama-server — never
  list `mmproj*` or `mtp-*` entries.
- `DEFAULTS` is a **bash array**.  Flag-value pairs are adjacent elements
  (e.g. `--n-predict 32768` is two elements: `--n-predict` and `32768`).
- Do **not** include `--ctx-size` in profiles. Binary backends let llama-server
  auto-fit context to available VRAM. For container backends (`--cuda`,
  `--cuda12`) the user can pass `-- --ctx-size <N>` at the command line since
  the container cannot see host VRAM.
- `--n-gpu-layers 999` means "offload all layers to GPU" — always include this.
- `--flash-attn on` should always be included.
- Only include `--reasoning-budget` if reasoning is `on`.
- Include `--reasoning-budget-message` for any reasoning model that uses a
  budget — this prevents partial `<think>` block leakage when the budget is
  exhausted.  The canonical message is:
  `$'\n\nOkay, I need to stop thinking and give my response now.\n'`
- Use native llama-server flag names (e.g. `--ctx-size`, not `-c`).
- Values with embedded spaces or newlines must use `$'...'` quoting.

After writing the profile, show the user the file contents and ask for
confirmation.

---

## Step 4 — Show how to run it

Ask the user about their hardware to determine which backend to use:

| Flag            | Backend                                        |
|-----------------|------------------------------------------------|
| `--cpu`         | CPU-only binary (upstream llama.cpp release)   |
| `--rocm`        | AMD ROCm binary (upstream llama.cpp release)   |
| `--rocm-nightly`| AMD ROCm binary (lemonade-sdk nightly)         |
| `--vulkan`      | Vulkan binary (upstream llama.cpp release)     |
| `--cuda`        | NVIDIA CUDA 13 (container via podman/docker)   |
| `--cuda12`      | NVIDIA CUDA 12 (container via podman/docker)   |

Print the run command:

```bash
./run.sh --<backend> --profile <name>
```

Mention that `--dry-run` prints the full underlying command, and that extra
llama-server flags can be passed after `--`:

```bash
./run.sh --rocm --profile <name> -- --ctx-size 110000
```

Binary backends run a cached llama.cpp build from `bin/`. If nothing is
cached, `run.sh` asks `backends.sh` to download the latest on first use.
Manage builds directly with `backends.sh` (`update`/`use`/`list`/`prune`).
Pin a tag for a single run with `--release TAG` or the `LLAMA_RELEASE`
environment variable — this does not change the saved default in
`bin/current`.

Container backends (`--cuda`, `--cuda12`) require podman or docker, the
NVIDIA Container Toolkit (`nvidia-ctk`) for GPU access, and pull the upstream
ghcr.io image. All container runs use `--network host` (required due to a
podman rootless pasta bug with IPv6). The HuggingFace cache is auto-created
on first run if missing.

---

## Reference: existing profiles

Look at the existing profiles in `profiles/` for style and format reference.
Key files:

- `profiles/gemma-4-12b-mtp.sh` — vision + MTP + reasoning model
- `profiles/qwen3.6-27b-mtp.sh` — MTP speculative decoding, reasoning, no vision
- `profiles/wayfarer-2-12b.sh`  — roleplay model, no vision, no reasoning

## Reference: key scripts

- `run.sh`                  — unified launcher (binary and container backends)
- `backends.sh`             — backend lifecycle (update/use/list/prune/current)
- `scripts/test-context.sh` — needle-in-haystack context window stress test
