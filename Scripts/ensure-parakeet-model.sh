#!/usr/bin/env bash
# Fetch the same pinned Parakeet bundle offered by the model picker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-v3}"
case "$VERSION" in
  v2)
    SHA256="6fc4426b54aa549a0019b8a75b8dea59164e71790a37ac56a045ad57f915f714"
    OVERRIDE="${VX_PARAKEET_V2_MODEL_PATH:-}"
    ;;
  v3)
    SHA256="1495e91b59d7fc53ddca91f3431758ec99f8fa253fdb0e1e851be0f72b14b0f9"
    OVERRIDE="${VX_PARAKEET_MODEL_PATH:-}"
    ;;
  *) echo "Usage: $0 [v2|v3]" >&2; exit 1 ;;
esac
NAME="sherpa-onnx-nemo-parakeet-tdt-0.6b-$VERSION-int8"
DEST="${OVERRIDE:-$ROOT/vx-ui/Resources/Models/$NAME}"
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
printf '%s  %s\n' "$SHA256" "$TMP/model.tar.bz2" | shasum -a 256 -c - >&2
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
