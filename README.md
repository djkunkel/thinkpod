# thinkpod2

Lightweight llama-server launcher using profiles. No baked-in model
images — models load directly from the local HuggingFace cache.

## Quick start

```bash
./run.sh --rocm --profile wayfarer-2-12b
```

Pick a backend for your hardware:

| Backend | Use for |
|---------|---------|
| `--cpu` | CPU-only inference |
| `--rocm` | AMD ROCm (upstream release) |
| `--rocm-nightly` | AMD ROCm (lemonade-sdk nightly builds) |
| `--vulkan` | Vulkan (AMD iGPU, Intel, etc.) |
| `--cuda` | NVIDIA CUDA 13 (container; requires nvidia-container-toolkit) |
| `--cuda12` | NVIDIA CUDA 12 (container; requires nvidia-container-toolkit) |

The server starts in the foreground and is available at
`http://localhost:8080`. See available profiles with `ls profiles/` or
omit `--profile` to be prompted.

### Override defaults at run time

Append extra llama-server flags after `--`:

```bash
./run.sh --rocm --profile wayfarer-2-12b -- --ctx-size 65536 --n-predict 8192
```

Pin a specific release tag for one run (binary backends) without changing
the saved selection:

```bash
./run.sh --rocm --profile wayfarer-2-12b --release b3456
```

### Dry run

Print the full command without executing it:

```bash
./run.sh --rocm --profile wayfarer-2-12b --dry-run
```

## Backends

`run.sh` runs a cached llama-server build (binary backends) or a ghcr.io
image (container backends). It never downloads anything itself — selection
and downloads are handled by `backends.sh`, which records the current
choice per backend in the gitignored `bin/current` file. If no build is
cached, `run.sh` asks `backends.sh update` to fetch one.

```bash
./backends.sh update  --rocm                # download latest, mark current
./backends.sh update  --rocm --release b3456  # download a pinned tag
./backends.sh use     --rocm --release b3456  # select an already-cached build
./backends.sh list                        # show cached builds + current
./backends.sh prune --keep 2              # remove old builds, keep newest 2
```

See `./backends.sh --help` for full options. Binary builds cache under
`bin/<backend>/<tag>/` (`bin/rocm-nightly/<tag>-<gfx>/` for nightly).

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HF_HUB` | `~/.cache/huggingface/hub` | HuggingFace cache directory (auto-created if missing) |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8080` | Bind port |
| `ENGINE` | auto-detected | Container engine: `podman` or `docker` |
| `LLAMA_RELEASE` | *(latest / `bin/current`)* | Pin a release tag for one run (binary backends) |
| `IMAGE` | per-backend ghcr.io tag | Override container image (container backends) |

`ROCM_VERSION`, `ROCM_NIGHTLY_REPO`, `ROCM_GFX`, and `ARCH` are honored by
`backends.sh` when downloading — see `./backends.sh --help`.

## Test the context window

```bash
./scripts/test-context.sh                       # test localhost:8080 at 75% fill
./scripts/test-context.sh 9090                   # different port
./scripts/test-context.sh cowboy.lan:8080 0.9    # remote host, 90% fill
```

## Creating a new profile

Use the `new-profile` opencode skill — it guides you through finding a
model on HuggingFace, researching the correct settings, and writing the
profile file. Alternatively, copy an existing profile and adjust the
variables:

```bash
REPO="org/Model-GGUF"
FILES=("Model-Q4_K_M.gguf")        # bash array; add "mmproj-F16.gguf" for vision
TEMPLATE="my-chat-template.jinja"  # optional; file must live in templates/
DEFAULTS=(
    --n-predict 32768
    --n-gpu-layers 999
    --flash-attn on
    --temperature 1.0
    --top-k 20
    --top-p 0.95
    --presence-penalty 1.5
    --reasoning on
)
```

Never include `--ctx-size` — binary backends auto-fit context to available
VRAM. Pass it at the command line (`-- --ctx-size N`) only when needed
(e.g. container backends, which can't introspect host VRAM). See
`profiles/README.md` for the full llama-server flag reference.

## Directory layout

```
thinkpod2/
├── run.sh                 # Launcher — builds llama-server args + runs the backend
├── backends.sh            # Backend lifecycle — update/use/list/prune/current
├── profiles/              # Model profiles (one .sh file per model variant)
│   └── README.md          # llama-server flag reference
├── templates/             # Custom Jinja chat templates (.jinja files)
├── scripts/
│   └── test-context.sh    # Context window stress test
├── bin/                   # Cached binaries + `current` state (gitignored)
└── .opencode/
    └── skills/
        └── new-profile/
            └── SKILL.md   # Skill for creating new profiles interactively
```
