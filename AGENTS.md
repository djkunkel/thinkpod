# thinkpod2 — Agent Instructions

This repo is a lightweight llama-server launcher. It has no build system, no
tests, and no compiled code. Changes are almost always to shell scripts and
profile files.

## Repository layout

```
thinkpod2/
├── run.sh                 # Launcher — builds llama-server args + runs the backend
├── backends.sh            # Backend lifecycle — update/use/list/prune/current
├── profiles/              # Model profiles — one .sh file per model variant
│   └── README.md          # llama-server flag reference
├── templates/             # Custom Jinja chat templates (.jinja files)
├── scripts/
│   └── test-context.sh    # Needle-in-haystack context window stress test
├── bin/                   # Cached llama.cpp binaries + `current` state (gitignored)
└── .opencode/
    └── skills/
        └── new-profile/
            └── SKILL.md   # Skill for creating new profiles interactively
```

## Profile format

A profile is a bash file sourced by `run.sh`. It sets three variables:

```bash
REPO="org/Model-GGUF"                      # HuggingFace repo
FILES=("Model-Q4_K_M.gguf")                # GGUF file(s); add mmproj for vision
TEMPLATE="my-chat-template.jinja"          # Optional: filename in templates/
DEFAULTS=(                                 # llama-server flags as a bash array
    --n-predict 32768
    --n-gpu-layers 999
    --flash-attn on
    --temperature 1.0
    --top-k 20
    --min-p 0.0
    --top-p 0.95
    --presence-penalty 1.5
    --reasoning on
)
```

Key rules:
- **Never include `--ctx-size`** in a profile. Binary backends let llama-server
  auto-fit context to available VRAM. For container backends (`--cuda`,
  `--cuda12`) pass `-- --ctx-size <N>` at the command line since the container
  cannot introspect host VRAM.
- `FILES` and `DEFAULTS` are bash arrays — use parentheses and quoted elements.
- `TEMPLATE` is a bare filename (no path); the file must exist in `templates/`.
  `run.sh` resolves it automatically and injects `--jinja --chat-template-file`.
- `--n-gpu-layers 999` and `--flash-attn on` should always be present.
- For MTP (Multi-Token Prediction) models add `--spec-type draft-mtp` and
  `--spec-draft-n-max 2`.
- For reasoning models add `--reasoning on`. Add `--reasoning-budget <N>` and
  `--reasoning-budget-message` only if a budget is needed to prevent think-block
  leakage.

## run.sh

```bash
./run.sh --<backend> --profile <name> [--dry-run] [-- extra llama-server flags]
```

Binary backends (run a cached llama.cpp release binary from `bin/`):
`--cpu`, `--rocm`, `--rocm-nightly`, `--vulkan`

Container backends (run a ghcr.io image via podman/docker):
`--cuda`, `--cuda12`

`run.sh` does not download anything itself. It resolves the backend to use
via `backends.sh current` (reading the selected build/image from the
gitignored `bin/current` file, falling back to the newest cached build, and
if nothing is cached, invoking `backends.sh update` to fetch one). `--release`
pins a specific tag for a single run without changing `bin/current`.

The `--rocm-nightly` backend uses ZIP builds from `lemonade-sdk/llamacpp-rocm`
(configurable via `ROCM_NIGHTLY_REPO`) instead of upstream llama.cpp tarballs.
The GPU target is selected via `ROCM_GFX` (default `gfx120X`); builds are
cached under `bin/rocm-nightly/<tag>-<gfx>/`.

Container backends accept `--template-dir <dir>` to mount a custom template
directory into the container at `/templates`. It defaults to `templates/` if
that directory exists.

Container backends (`--cuda`, `--cuda12`) require the NVIDIA Container Toolkit
(`nvidia-ctk`) on the host for GPU access — `run.sh` checks for it and fails
fast with install instructions if missing. The HuggingFace cache (`HF_HUB`)
is created automatically if absent so a fresh host can download the model on
first run; `--dry-run` previews the command without creating it.

The script does not exit on its own — it runs llama-server in the foreground.

## backends.sh

```bash
./backends.sh <subcommand> --<backend> [options]
```

Owns the `bin/` cache lifecycle for all backends (binary and container):

- `update [--release TAG]` — download/pull the latest (or pinned) build and
  mark it current in `bin/current`.
- `use --release TAG` — mark an already-cached binary build as current (no
  download; binary backends only).
- `list [--<backend>]` — show cached builds/images with the current marked.
- `prune [--keep N]` — delete non-current cached builds (binary) and dangling
  images (container). `--keep N` preserves the N newest per binary backend.
- `current [--release TAG]` — print the current cache dir (binary) or image
  ref (container); used by `run.sh`. Exits 1 if a binary backend has no
  cached build.

State file: `bin/current` (gitignored) holds `<backend>=<value>` lines, where
value is the cache subdir name (binary) or image ref (container).

## Making changes

**Adding a profile:** create `profiles/<name>.sh`. Follow the format above.
Use an existing profile as a reference. Do not add `--ctx-size`.

**Adding a chat template:** place the `.jinja` file in `templates/` and set
`TEMPLATE="<filename>.jinja"` in the relevant profile(s).

**Modifying run.sh:** plain bash with `set -euo pipefail`. Always run
`bash -n run.sh` to syntax-check after editing. The profile is sourced after
argument parsing; variables set in the profile (`REPO`, `FILES`, `DEFAULTS`,
`TEMPLATE`) must be initialized to empty defaults before the `source` call.
Backend download/selection logic lives in `backends.sh`; `run.sh` should stay
a thin launcher that calls `backends.sh current`/`update`.

**Modifying backends.sh:** plain bash with `set -euo pipefail`. Always run
`bash -n backends.sh` after editing. Keep `current`'s output contract stable
(absolute cache dir for binary backends, image ref for containers; exit 1
only when a binary backend has no cached build) — `run.sh` depends on it.

**Updating the skill:** the `new-profile` skill at
`.opencode/skills/new-profile/SKILL.md` is the authoritative guide for
creating profiles interactively. Keep it consistent with any changes to the
profile format or script behavior.

## What not to do

- Do not add a build system, Makefile, or CI pipeline unless explicitly asked.
- Do not add `--ctx-size` to profiles — llama-server auto-fits on bare metal.
- Do not hardcode VRAM budgets or context size guesses into profiles.
- Do not modify `bin/` contents (gitignored, managed by `backends.sh`).
- Do not add dependencies beyond standard POSIX utilities (`bash`, `curl`, `tar`).
