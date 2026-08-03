#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

model_name="$(awk -F '\t' '$1 == "base.en" { print $10; exit }' "$ROOT_DIR/models/models.tsv")"
[[ -n "$model_name" ]] || { printf 'base.en is missing from the model manifest\n' >&2; exit 1; }

mkdir -p "$tmp/output/bin" "$tmp/models"
printf 'native whisper.cpp output directory\n' >"$tmp/output/.native-builder-output"
printf 'model fixture\n' >"$tmp/models/$model_name"
printf 'audio fixture\n' >"$tmp/audio.wav"

cat >"$tmp/output/bin/whisper-cli" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" >"${CAPTURE_ARGS:?}"
SH
chmod 0755 "$tmp/output/bin/whisper-cli"

env \
    CONFIG_FROM_MAKE=1 \
    ROOT_DIR="$ROOT_DIR" \
    SOURCE_DIR="$tmp/source" \
    BUILD_DIR="$tmp/build" \
    OUTPUT_DIR="$tmp/output" \
    MODEL_DIR="$tmp/models" \
    ALLOW_EXTERNAL_DIRS=1 \
    ENABLE_CUDA=0 \
    ENABLE_HIP=0 \
    ENABLE_VULKAN=0 \
    ENABLE_SYCL=0 \
    ENABLE_SYCL_F16=0 \
    AUDIO="$tmp/audio.wav" \
    MODEL=base.en \
    RUNTIME_THREADS=1 \
    RUN_ARGS='--output-txt' \
    CAPTURE_ARGS="$tmp/args.txt" \
    "$ROOT_DIR/scripts/run.sh" >/dev/null

printf '%s\n' \
    --model \
    "$tmp/models/$model_name" \
    --file \
    "$tmp/audio.wav" \
    --threads \
    1 \
    --output-txt >"$tmp/expected-args.txt"
cmp -- "$tmp/expected-args.txt" "$tmp/args.txt"
