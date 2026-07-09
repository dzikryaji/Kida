#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

load_server_secrets() {
  local file="$1"
  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" || "$line" == \#* || "$line" == //* || "$line" != *=* ]] && continue

    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key//[[:space:]]/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    case "$key" in
      KIDA_TAVILY_API_KEY|TAVILY_API_KEY|KIDA_TAVILY_TIMEOUT|KIDA_TAVILY_CACHE_TTL)
        if [ -z "${!key:-}" ] && [ -n "$value" ]; then
          export "$key=$value"
        fi
        ;;
    esac
  done < "$file"
}

load_server_secrets "Server/.env"
load_server_secrets "Server/.env.local"
load_server_secrets "Server/secrets.env"
load_server_secrets "Supporting/Secrets.xcconfig"

MODEL="${KIDA_MLX_VLM_MODEL:-mlx-community/Qwen3-VL-4B-Instruct-3bit}"
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
elif [ -z "${KIDA_VLM_SOURCE:-}" ] && [[ "$MODEL" == *Qwen3-VL* ]]; then
  export KIDA_VLM_SOURCE="mlx-qwen3-vl"
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
