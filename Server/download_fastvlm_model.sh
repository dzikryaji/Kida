#!/usr/bin/env bash
set -euo pipefail

MODEL_SIZE="${1:-0.5b}"
DEST="${2:-Server/fastvlm-${MODEL_SIZE}}"

case "$MODEL_SIZE" in
  0.5b) MODEL="llava-fastvithd_0.5b_stage3_llm.fp16" ;;
  1.5b) MODEL="llava-fastvithd_1.5b_stage3_llm.int8" ;;
  7b) MODEL="llava-fastvithd_7b_stage3_llm.int4" ;;
  *)
    echo "Usage: $0 [0.5b|1.5b|7b] [destination]" >&2
    exit 2
    ;;
esac

URL="https://ml-site.cdn-apple.com/datasets/fastvlm/${MODEL}.zip"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$DEST"
if [ -n "$(find "$DEST" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
  echo "Destination is not empty: $DEST" >&2
  echo "Move it away or pass a new destination." >&2
  exit 1
fi

echo "Downloading Apple FastVLM ${MODEL_SIZE} to ${DEST}"
curl -L "$URL" -o "$TMP_DIR/${MODEL}.zip"
unzip -q "$TMP_DIR/${MODEL}.zip" -d "$TMP_DIR"
cp -R "$TMP_DIR/${MODEL}/." "$DEST/"
echo "Downloaded: $DEST"
