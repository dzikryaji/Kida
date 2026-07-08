#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export KIDA_MLX_PYTHON="${KIDA_MLX_PYTHON:-.venv-fastvlm/bin/python}"
export KIDA_MLX_VLM_MODEL="${KIDA_MLX_VLM_MODEL:-Server/fastvlm-0.5b}"
export KIDA_VLM_SOURCE="${KIDA_VLM_SOURCE:-apple-fastvlm}"
export KIDA_FASTVLM_TIMEOUT="${KIDA_FASTVLM_TIMEOUT:-180}"

bash Server/run_mlx_server.sh
