# AMD Radeon AI PRO R9700 Migration Plan

Plan for replacing the NVIDIA RTX 4070 12GB with an AMD Radeon AI PRO R9700
32GB (gfx1201, RDNA 4) and switching from CUDA to ROCm.

## Hardware comparison

| | RTX 4070 (current) | Radeon AI PRO R9700 |
|---|---|---|
| Architecture | Ada Lovelace | RDNA 4 |
| LLVM target | N/A | gfx1201 |
| VRAM | 12 GB GDDR6X | 32 GB GDDR6 |
| Compute units | 46 SMs | 64 CUs |
| Wave size | 32 | 32 |
| PCIe | Gen 4 | Gen 5 |
| ROCm support | N/A | ROCm 7.2.1+ (officially listed) |
| Container image | `server-cuda13` | `server-rocm` |

The 2.7x VRAM increase (12 GB -> 32 GB) means much larger models (e.g.,
Qwen3.5-35B-A3B quantized) or significantly longer contexts become possible.

## What changes in serve.sh

The changes are minimal. Only the container image and GPU passthrough flags
differ:

### Container image

```sh
# Current (NVIDIA)
IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda13

# AMD ROCm
IMAGE=ghcr.io/ggml-org/llama.cpp:server-rocm
```

Published on every llama.cpp release alongside the CUDA images. Built with
ROCm 7.2. Pin to a specific build with e.g. `server-rocm-b8808`.

### GPU passthrough

```sh
# Current (NVIDIA) -- uses CDI via nvidia-container-toolkit
--device nvidia.com/gpu=all

# AMD ROCm -- uses standard Linux DRI device nodes
--device /dev/kfd --device /dev/dri
```

No CDI, no nvidia-container-toolkit needed. Simpler stack.

### Security / SELinux

```sh
# Current (NVIDIA)
--security-opt label=disable

# AMD ROCm -- same, plus seccomp=unconfined for HIP memory mapping
--security-opt label=disable
--security-opt seccomp=unconfined
```

### Group access

```sh
# AMD ROCm -- needed for /dev/kfd and /dev/dri access in the container
--group-add video
```

### Everything else stays the same

- HF cache mount (`-v "$HF_HUB:/root/.cache/huggingface/hub:ro"`)
- Host networking (`--network host`)
- All llama-server flags (`-hf`, `--offline`, `--flash-attn on`, reasoning
  budget, etc.)
- test-context.sh (completely GPU-agnostic, talks to the HTTP API)

## Proposed implementation

Add a `GPU_BACKEND` variable with auto-detection:

```sh
# Auto-detect: check for AMD KFD device vs NVIDIA device
if [[ -z "${GPU_BACKEND:-}" ]]; then
    if [[ -e /dev/kfd ]]; then
        GPU_BACKEND=rocm
    elif [[ -e /dev/nvidia0 ]] || command -v nvidia-smi &>/dev/null; then
        GPU_BACKEND=cuda
    else
        echo "error: no GPU detected" >&2
        exit 1
    fi
fi
```

Then branch the podman flags based on `GPU_BACKEND`:

```sh
case "$GPU_BACKEND" in
    cuda)
        IMAGE="${IMAGE:-ghcr.io/ggml-org/llama.cpp:server-cuda13}"
        gpu_flags=(--device nvidia.com/gpu=all)
        ;;
    rocm)
        IMAGE="${IMAGE:-ghcr.io/ggml-org/llama.cpp:server-rocm}"
        gpu_flags=(
            --device /dev/kfd --device /dev/dri
            --security-opt seccomp=unconfined
            --group-add video
        )
        ;;
esac
```

Override manually if auto-detection gets it wrong (e.g., both GPUs installed
during transition):

```sh
GPU_BACKEND=rocm ./serve.sh
```

## Current system readiness

Checked on Bazzite 43 (2026-04-06 build):

### Kernel: READY

```
6.17.7-ba29.fc43.x86_64
```

ROCm documentation requires kernel >= 6.17 for RDNA 4 discrete GPUs
(gfx1201). This kernel meets that requirement. Bazzite ships a recent
enough kernel out of the box.

### amdgpu kernel module: READY

The `amdgpu` module is already present and loaded (it's built into the
Bazzite kernel for the integrated Intel GPU's DRI compatibility and general
AMD support):

```
$ lsmod | grep amdgpu
amdgpu              20688896  0
```

It will auto-detect the R9700 at boot via PCI enumeration. No manual driver
installation needed on Bazzite -- the kernel module and firmware are baked
into the OS image.

### GFX12 firmware: READY

The R9700 (gfx1201) maps to GC 12.0.1 firmware. All required firmware files
are already present in `/lib/firmware/amdgpu/`:

```
gc_12_0_1_imu.bin.xz         gc_12_0_1_pfp.bin.xz
gc_12_0_1_imu_kicker.bin.xz  gc_12_0_1_rlc.bin.xz
gc_12_0_1_me.bin.xz          gc_12_0_1_rlc_kicker.bin.xz
gc_12_0_1_mec.bin.xz         gc_12_0_1_toc.bin.xz
gc_12_0_1_mes1.bin.xz        gc_12_0_1_uni_mes.bin.xz
gc_12_0_1_mes.bin.xz
```

These ship with the Bazzite image. No extra firmware packages needed.

### Device nodes: READY

`/dev/kfd` and `/dev/dri/renderD128` already exist (currently for the NVIDIA
GPU's DRI fallback path). Once the R9700 is installed, the amdgpu driver
will claim these nodes for GPU compute.

```
/dev/kfd        -> 666 root:render (world-readable, already permissive)
/dev/dri/renderD128 -> 666 root:render (world-readable)
/dev/dri/card0      -> 660 root:video
```

### User groups: DONE (with Bazzite workaround)

The current user was **not** in the `video` or `render` groups. On Bazzite
(and other immutable Fedora variants), `sudo usermod -aG video dj` **silently
does nothing** -- it exits 0 but doesn't modify group membership.

**Why**: Bazzite uses a split group database:

- `/usr/lib/group` -- read-only OS image (has `video:x:39:`, `render:x:105:`)
- `/etc/group` -- local overrides (writable, but these groups aren't in it)
- NSS resolves both via `files [SUCCESS=merge] altfiles`

`usermod` sees the group exists (via NSS), but can't find it in `/etc/group`
to modify. It silently succeeds without changing anything.

**The fix**: Manually add the groups with the user to `/etc/group`:

```sh
sudo bash -c 'grep -q "^video:" /etc/group || echo "video:x:39:dj" >> /etc/group'
sudo bash -c 'grep -q "^render:" /etc/group || echo "render:x:105:dj" >> /etc/group'
```

This creates local entries that the `[SUCCESS=merge]` NSS directive combines
with the OS image entries. Verified working:

```
$ id dj
uid=1000(dj) gid=1000(dj) groups=1000(dj),10(wheel),1001(docker),960(libvirt),39(video),105(render)
```

Log out and back in for the current session to pick up the new groups.

Group membership is needed for rootless podman to access `/dev/dri/card0`
(which is `660 root:video`). The `renderD128` and `kfd` nodes are
world-accessible (`666`) so they work without group membership, but `card0`
access is required for full GPU functionality.

### nvidia-container-toolkit / CDI: NO LONGER NEEDED

The CDI config (`/etc/cdi/nvidia.yaml`) and nvidia-container-toolkit are
NVIDIA-specific. With the R9700, GPU passthrough is done through standard
Linux device nodes. These packages can be uninstalled after the swap.

### ROCm userspace: NOT NEEDED ON HOST

The ROCm userspace (HIP runtime, rocBLAS, etc.) lives entirely inside the
`server-rocm` container image. Only the kernel driver (`amdgpu`) needs to
be on the host -- and it already is.

## Performance expectations

Based on published benchmarks for gfx1201 / R9700:

### llama.cpp inference (single GPU)

| Model | Metric | R9700 (ROCm) | RTX 4070 (CUDA, current) |
|---|---|---|---|
| Qwen2.5-Coder-7B Q4_K_M | tg128 | ~99-105 tok/s | ~110 tok/s |
| Qwen3.5-14B-A3B MXFP4 | pp512 | ~3,731 tok/s | N/A |
| Qwen3.5-14B-A3B MXFP4 | tg128 | ~88 tok/s | N/A |

Token generation speed is roughly comparable to the RTX 4070. The R9700's
advantage is in VRAM capacity (32GB vs 12GB), enabling larger models.

### Critical: flash attention must be enabled

On RDNA 4, ROCm without flash attention is **catastrophically slow** -- up to
5.5x slower on prompt processing. Our serve.sh already passes
`--flash-attn on`, which is correct. Do not remove this flag.

### ROCm build flags matter

The official `server-rocm` container should be fine, but if you ever build
from source, these flags are important for RDNA 4 performance:

```
-DGGML_CUDA_FORCE_MMQ=ON -DGGML_HIP_GRAPHS=ON
```

## Known issues (as of April 2026)

### 1. GPU idle power bug (HIP backend)

There's a [reported issue](https://github.com/ROCm/ROCm/issues/5706) where
the HIP/ROCm backend causes R9700 GPUs to stay at 100% utilization even when
idle. The Vulkan backend does not have this issue. Reports indicate this is
being fixed in newer kernel/firmware updates. Check if it's resolved before
going all-in on ROCm -- if not, Vulkan is an alternative backend:

```sh
IMAGE=ghcr.io/ggml-org/llama.cpp:server ./serve.sh  # CPU+Vulkan image
```

### 2. Vulkan may outperform ROCm on token generation

Some benchmarks show Vulkan outperforming ROCm on token generation
(especially for MoE models), while ROCm wins on prompt processing. This is
actively being improved as RDNA 4 ROCm kernels mature.

### 3. MoE model regression

There was a [reported regression](https://github.com/ggml-org/llama.cpp/pull/19478)
in MMVQ parameters on RDNA 4 specifically affecting MoE models (Qwen3.5
35B-A3B, 122B-A10B) with multi-GPU setups. Single GPU should be fine, but
worth testing if you run MoE models.

### 4. Bazzite is an immutable distro

You can't `dnf install rocm-dev` on the host. But this doesn't matter --
ROCm userspace lives in the container. The only host requirements (kernel
driver + firmware) are already baked into the OS image. If you need `rocminfo`
or `rocm-smi` on the host for debugging, use a container:

```sh
podman run --rm --device /dev/kfd --device /dev/dri \
    rocm/dev-ubuntu-24.04:7.2 rocminfo
```

## Migration checklist

When you have the R9700 installed:

- [ ] **Physical install**: Swap RTX 4070 for R9700, connect power
- [ ] **First boot**: Verify `amdgpu` loads: `lsmod | grep amdgpu`
- [ ] **Device nodes**: Verify `/dev/kfd` and `/dev/dri/renderD128` exist
- [x] **User groups**: Added `video` + `render` (see Bazzite workaround above) -- re-login needed to activate
- [ ] **Smoke test**: `podman run --rm --device /dev/kfd --device /dev/dri rocm/dev-ubuntu-24.04:7.2 rocminfo`
- [ ] **Pull image**: `podman pull ghcr.io/ggml-org/llama.cpp:server-rocm`
- [ ] **Update serve.sh**: Set `GPU_BACKEND=rocm` (or implement auto-detection)
- [ ] **Test**: `./serve.sh` and verify GPU inference works
- [ ] **Context test**: `./test-context.sh` -- with 32GB VRAM, you can try much larger contexts
- [ ] **Idle power check**: After inference completes, check `rocm-smi` or `cat /sys/class/drm/card0/device/gpu_busy_percent` to verify GPU idles properly
- [ ] **Cleanup (optional)**: Remove nvidia-container-toolkit, `/etc/cdi/nvidia.yaml`, and NVIDIA driver packages if no longer needed
- [ ] **Cleanup (optional)**: Remove old ramalama model store (`~/.local/share/ramalama/`)
