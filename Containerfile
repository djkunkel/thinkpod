# Self-contained llama-server image with model baked in.
#
# Build args:
#   BASE_IMAGE     - upstream llama.cpp server image (CUDA, ROCm, or Vulkan)
#   HF_REPO        - HuggingFace repo name (e.g. unsloth/Qwen3.5-4B-GGUF)
#   HF_REPO_CACHE  - cache dir name (e.g. models--unsloth--Qwen3.5-4B-GGUF)
#   COMMIT_HASH    - snapshot commit hash (from HF cache refs/main)
#
# These are set automatically by build.sh from the MANIFEST file.

ARG BASE_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda13

FROM ${BASE_IMAGE}

ARG HF_REPO=unsloth/Qwen3.5-4B-GGUF
ARG HF_REPO_CACHE=models--unsloth--Qwen3.5-4B-GGUF
ARG COMMIT_HASH=0000000000000000000000000000000000000001

# Set up the HF cache directory structure so that:
#   llama-server -hf $HF_REPO --offline
# resolves the model files automatically, including mmproj auto-detection
# for multimodal/vision models.
RUN mkdir -p "/root/.cache/huggingface/hub/${HF_REPO_CACHE}/refs" \
    && mkdir -p "/root/.cache/huggingface/hub/${HF_REPO_CACHE}/snapshots/${COMMIT_HASH}" \
    && echo -n "${COMMIT_HASH}" > "/root/.cache/huggingface/hub/${HF_REPO_CACHE}/refs/main"

# Copy staged model files (GGUF + optional mmproj) into the snapshot directory.
# The filenames are preserved so llama-server's -hf flag can match them by
# quantization tag and detect mmproj files by name.
COPY models/*.gguf "/root/.cache/huggingface/hub/${HF_REPO_CACHE}/snapshots/${COMMIT_HASH}/"

# Copy runtime defaults and entrypoint, patch in the default model name
COPY defaults.conf /defaults.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && sed -i "s|__DEFAULT_MODEL__|${HF_REPO}|g" /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
