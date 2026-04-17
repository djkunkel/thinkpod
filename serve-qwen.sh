#!/usr/bin/env bash

exec ramalama serve \
    --privileged \
    --oci-runtime /usr/bin/crun \
    --host 0.0.0.0 \
    --port 8080 \
    -c 32768 \
    --max-tokens 8000 \
    --temp 1.0 \
    --thinking true \
    --runtime-args "--top-k 20 --top-p 0.95 --presence-penalty 1.8 --reasoning-budget 2500 --metrics" \
    "hf://unsloth/Qwen3.5-4B-GGUF"
