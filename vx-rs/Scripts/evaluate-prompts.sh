#!/bin/sh
# Compare Whisper prompt variants against one 16 kHz mono WAV fixture.
#
# Usage:
#   ./Scripts/evaluate-prompts.sh /path/to/model.bin /path/to/audio.wav [output-directory]
#
# The output directory contains one transcript and one audio-metrics log per
# prompt mode. Review the three transcripts together; this script does not make
# an automated quality claim because fixtures need human/ground-truth context.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
crate_dir=$(dirname "$script_dir")

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: $0 MODEL AUDIO [OUTPUT_DIRECTORY]" >&2
    exit 64
fi

model=$1
audio=$2
output_dir=${3:-"$crate_dir/build/prompt-evaluation"}
backend=${VX_BACKEND_PATH:-"$crate_dir/target/release/vx-rs"}

if [ ! -f "$model" ]; then
    echo "model not found: $model" >&2
    exit 66
fi
if [ ! -f "$audio" ]; then
    echo "audio fixture not found: $audio" >&2
    exit 66
fi
if [ ! -x "$backend" ]; then
    echo "building release backend…" >&2
    cargo build --release --manifest-path "$crate_dir/Cargo.toml"
fi

mkdir -p "$output_dir"

for mode in current short none; do
    echo "evaluating prompt mode: $mode" >&2
    "$backend" file "$model" "$audio" \
        --prompt-mode "$mode" \
        --report-audio-metrics \
        > "$output_dir/$mode.txt" \
        2> "$output_dir/$mode.metrics.log"
done

echo "Results written to: $output_dir"
echo "Compare with: diff -u $output_dir/current.txt $output_dir/short.txt"
echo "              diff -u $output_dir/current.txt $output_dir/none.txt"
