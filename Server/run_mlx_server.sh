#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

MODEL="${KIDA_MLX_VLM_MODEL:-mlx-community/Qwen2.5-VL-3B-Instruct-4bit}"
if [ -z "${KIDA_MLX_PYTHON:-}" ] && [[ "$MODEL" == *fastvlm* ]] && [ -x ".venv-fastvlm/bin/python" ]; then
  PYTHON=".venv-fastvlm/bin/python"
else
  PYTHON="${KIDA_MLX_PYTHON:-.venv/bin/python}"
fi

export KIDA_MLX_VLM_MODEL="$MODEL"
if [ -z "${KIDA_VLM_SOURCE:-}" ] && [[ "$MODEL" == *fastvlm* ]]; then
  export KIDA_VLM_SOURCE="apple-fastvlm"
elif [ -z "${KIDA_VLM_SOURCE:-}" ] && [[ "$MODEL" == *SmolVLM* || "$MODEL" == *smolvlm* ]]; then
  export KIDA_VLM_SOURCE="mlx-smolvlm"
elif [ -z "${KIDA_VLM_SOURCE:-}" ] && [[ "$MODEL" == *Qwen2.5-VL* ]]; then
  export KIDA_VLM_SOURCE="mlx-qwen2.5-vl-3b"
else
  export KIDA_VLM_SOURCE="${KIDA_VLM_SOURCE:-mlx-qwen2-vl}"
fi
export KIDA_FASTVLM_COMMAND="$PYTHON Server/mlx_vlm_runner.py --model $MODEL --image {image} --prompt-file {prompt}"

echo "Kida VLM model: $MODEL"
echo "Kida VLM python: $PYTHON"
echo "Kida VLM source: $KIDA_VLM_SOURCE"

"$PYTHON" Server/kida_vlm_server.py \
  --host "${KIDA_VLM_HOST:-0.0.0.0}" \
  --port "${KIDA_VLM_PORT:-8787}" \
  --token "${KIDA_VLM_SERVER_TOKEN:-local-dev-token}" \
  --fastvlm-timeout "${KIDA_FASTVLM_TIMEOUT:-120}"
