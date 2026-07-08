#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export KIDA_MLX_PYTHON="${KIDA_MLX_PYTHON:-.venv/bin/python}"
export KIDA_MLX_VLM_MODEL="${KIDA_MLX_VLM_MODEL:-mlx-community/SmolVLM2-500M-Video-Instruct-mlx}"
export KIDA_VLM_SOURCE="${KIDA_VLM_SOURCE:-mlx-smolvlm2}"
export KIDA_FASTVLM_TIMEOUT="${KIDA_FASTVLM_TIMEOUT:-180}"

bash Server/run_mlx_server.sh
