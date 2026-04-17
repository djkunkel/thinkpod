# R9700 PRO Performance Estimates

Pre-install performance estimates for the AMD Radeon AI PRO R9700 (32GB,
gfx1201, RDNA 4) compared to the current NVIDIA RTX 4070 (12GB). Compiled
April 2026 from published benchmarks and community testing. To be compared
against actual results after installation.

## Current baseline (RTX 4070 12GB, CUDA)

From README.md, measured on this machine:

| Metric | Value |
|---|---|
| Model | Qwen3.5-4B Q4_K_M |
| Token generation | ~110 tok/s |
| Prompt processing | ~627 tok/s |
| Context window | 48K (fits in 12GB VRAM, no KV quant) |

## Estimated R9700 token generation (models that fit in 12GB)

Token generation is memory-bandwidth-bound. The R9700 has ~512-640 GB/s
bandwidth (depending on MCLK level) vs the RTX 4070's ~504 GB/s, so for
models that already fit on the 4070, speeds should be roughly comparable.

| Model | RTX 4070 (actual) | R9700 ROCm (est.) | R9700 Vulkan (est.) | Source |
|---|---|---|---|---|
| Qwen2.5-Coder-7B Q4_K_M | ~110 tok/s | ~99-105 tok/s | ~100-110 tok/s | tlee933/llama.cpp-rdna4-gfx1201, AMDPLAN.md |
| Qwen3.5-4B Q4_K_M (current) | ~110 tok/s | ~100-110 tok/s | ~100-115 tok/s | Extrapolated from 7B results |
| Llama 3.1 8B Q8_0 | N/A | ~69 tok/s | ~176 tok/s | OpenBenchmarking.org |

Note: Vulkan often outperforms ROCm on token generation by ~5-20% on RDNA 4.
ROCm wins on prompt processing by ~30-100%.

## Estimated R9700 performance on larger models (new capability)

These models do NOT fit in 12GB VRAM and cannot run on the RTX 4070. This is
where the 32GB VRAM advantage matters.

| Model | R9700 ROCm (est.) | R9700 Vulkan (est.) | Source |
|---|---|---|---|
| Qwen3.5-35B-A3B MoE Q4_K_XL, tg128 | ~74 tok/s | ~127-164 tok/s | llama.cpp #19890, #21043 |
| Qwen3.5-35B-A3B MoE Q4_K_XL, pp2048 | ~1,895 tok/s | ~2,610 tok/s | llama.cpp #19890, ai-navigate |
| Qwen3.5-14B-A3B MXFP4, tg128 | ~88 tok/s | N/A | AMDPLAN.md |
| Qwen2.5 32B Q6_K, tg256 | ~19 tok/s | ~19 tok/s | ai-navigate shootout |
| Qwen3 32B Q4, response | N/A | ~23 tok/s | meefik.github.io |
| DeepSeek-R1 32B Q4, response | N/A | ~23 tok/s | meefik.github.io |
| Gemma3 27B, response | N/A | ~27 tok/s | meefik.github.io |
| gpt-oss 20B MoE, response | N/A | ~91 tok/s | meefik.github.io |
| Mistral 7B, response | N/A | ~80 tok/s | meefik.github.io |
| Phi4 14B, response | N/A | ~50 tok/s | meefik.github.io |

## Prompt processing comparison

| Model | RTX 4070 (actual) | R9700 ROCm (est.) | R9700 Vulkan (est.) |
|---|---|---|---|
| Qwen3.5-4B Q4_K_M | ~627 tok/s | ~500-600 tok/s | ~300-400 tok/s |
| Qwen3.5-35B-A3B MoE Q4, pp2048 | N/A (OOM) | ~1,895 tok/s | ~2,610 tok/s |
| Qwen2.5 32B Q6_K, pp2048 | N/A (OOM) | ~526 tok/s | ~235 tok/s |

## Context window expectations

| GPU | VRAM | Model | Max context (est.) |
|---|---|---|---|
| RTX 4070 | 12 GB | Qwen3.5-4B Q4_K_M | 48K (tested, no KV quant) |
| R9700 | 32 GB | Qwen3.5-4B Q4_K_M | 128K+ (estimated) |
| R9700 | 32 GB | Qwen3.5-35B-A3B MoE Q4 | 32-48K (estimated) |
| R9700 | 32 GB | Qwen3 32B Q4 | 8-16K (estimated, tight) |

## Backend recommendation

Based on benchmarks as of April 2026:

- **Vulkan (RADV)** is likely the best default for interactive use (token
  generation). No ROCm userspace needed. Use the `server` image:
  ```sh
  IMAGE=ghcr.io/ggml-org/llama.cpp:server ./serve.sh
  ```

- **ROCm (HIP)** wins on prompt processing / prefill, which matters for long
  context. Use the `server-rocm` image:
  ```sh
  IMAGE=ghcr.io/ggml-org/llama.cpp:server-rocm ./serve.sh
  ```

- **Test both** after install and pick based on your workload.

## Known risks at time of estimate

1. **GPU idle power bug** -- ROCm/HIP keeps RDNA 4 GPUs at 100% utilization
   even when idle (ROCm/ROCm#5706, closed March 2026). Fix is via
   firmware/MES update. Vulkan is unaffected. Verify after install.

2. **ROCm 7.x performance regression** -- ROCm 7.2 can be up to 3x slower
   than 6.4.4 on some workloads due to a compiler unroll heuristic bug
   (ROCm/rocm-systems#2865, open). Check if patched.

3. **Flash attention is critical** -- Without `--flash-attn on`, RDNA 4 ROCm
   prompt processing is up to 5.5x slower. serve.sh already passes this flag.

4. **MoE model regression on multi-GPU** -- Reported MMVQ regression on RDNA 4
   for MoE models in multi-GPU setups (llama.cpp#19478). Single GPU should be
   fine.

5. **Vulkan vs ROCm maturity** -- RDNA 4 ROCm kernels are still maturing.
   Vulkan (via RADV/Mesa) has been more stable and sometimes faster for token
   generation.

## Summary

The R9700 is NOT a speed upgrade for models that fit in 12GB. It is a
**capacity upgrade**:

- Same-speed inference on current workloads (~100-110 tok/s on 4-7B models)
- Ability to run 30-35B class models at interactive speeds (23-164 tok/s)
- Much larger context windows
- Simpler GPU passthrough stack (no CDI/nvidia-container-toolkit needed)

## Benchmark sources

- tlee933/llama.cpp-rdna4-gfx1201 (GitHub, Jan 2026)
- llama.cpp Discussion #19890: RTX 5090 vs R9700 Vulkan (Feb 2026)
- llama.cpp Discussion #21043: RDNA4 Llama Experiments (Mar 2026)
- ai-navigate: Ultimate Llama.cpp Shootout (Mar 2026)
- OpenBenchmarking.org: Llama-cpp AMD R9700 Benchmarks (Nov 2025)
- Phoronix: AMD ROCm 7.1 vs RADV Vulkan for Llama.cpp (Nov 2025)
- meefik.github.io: LLM performance on AMD Radeon AI PRO R9700 (Nov 2025)
- AMD Quick Reference Guide: Radeon AI PRO R9700 (Aug 2025)
- ROCm/ROCm#5706: HIP idle power bug (closed Mar 2026)
- ROCm/rocm-systems#2865: ROCm 7+ performance regression (open)
