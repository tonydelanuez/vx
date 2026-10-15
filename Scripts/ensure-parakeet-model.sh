#!/usr/bin/env bash
# Fetch the same pinned Parakeet bundle offered by the model picker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
DEST="${VX_PARAKEET_MODEL_PATH:-$ROOT/vx-ui/Resources/Models/$NAME}"
FILES=(encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt)
complete=1
for file in "${FILES[@]}"; do
  [[ -s "$DEST/$file" ]] || complete=0
done
if [[ "$complete" == 1 ]]; then printf '%s\n' "$DEST"; exit 0; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL --retry 3 -o "$TMP/model.tar.bz2" \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$NAME.tar.bz2"
printf '%s  %s\n' 5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf "$TMP/model.tar.bz2" | shasum -a 256 -c - >&2
MEMBERS=()
for file in "${FILES[@]}"; do MEMBERS+=("$NAME/$file"); done
tar -xjf "$TMP/model.tar.bz2" -C "$TMP" "${MEMBERS[@]}"
for file in "${FILES[@]}"; do
  [[ -s "$TMP/$NAME/$file" && ! -L "$TMP/$NAME/$file" ]]
done
mkdir -p "$(dirname "$DEST")"
if [[ -e "$DEST" ]]; then
  echo "Incomplete model already exists at $DEST. Move it aside before retrying." >&2
  exit 1
fi
mv "$TMP/$NAME" "$DEST"
printf '%s\n' "$DEST"
