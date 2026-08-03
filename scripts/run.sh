#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

validate_common_config
[[ -r "$MANIFEST_PATH" ]] || die "Model manifest not found: $MANIFEST_PATH"

binary="$OUTPUT_DIR_ABS/bin/whisper-cli"
[[ -x "$binary" ]] || die "No staged whisper-cli at $binary; run make build"
[[ -n "${AUDIO:-}" ]] || die "AUDIO is required, for example: make run MODEL=base.en AUDIO=/path/file.wav"
[[ -f "$AUDIO" ]] || die "Audio file not found: $AUDIO"

selection="${MODEL:-base.en}"
model_path=''
if [[ -f "$selection" ]]; then
    model_path="$selection"
else
    while IFS=$'\t' read -r id family params_m file_mib min_ram rec_ram cores language precision local_name checksum_algo checksum url notes; do
        [[ -z "$id" || "$id" == \#* || "$id" == "id" ]] && continue
        if [[ "$id" == "$selection" ]]; then
            model_path="$MODEL_DIR_ABS/$local_name"
            break
        fi
    done <"$MANIFEST_PATH"
fi
[[ -n "$model_path" ]] || die "Unknown model: $selection"
[[ -f "$model_path" ]] || die "Model is not downloaded: $model_path. Run make download MODEL=$selection"

if [[ "$RUNTIME_THREADS" == "auto" || -z "$RUNTIME_THREADS" ]]; then
    threads="$(physical_cores)"
elif [[ "$RUNTIME_THREADS" =~ ^[1-9][0-9]*$ ]]; then
    threads="$RUNTIME_THREADS"
else
    die "RUNTIME_THREADS must be auto or a positive integer"
fi

extra=()
if [[ -n "${RUN_ARGS:-}" ]]; then
    read -r -a extra <<<"$RUN_ARGS"
fi

log "Running whisper-cli with $threads thread(s) and model $(basename "$model_path")"
exec "$binary" --model "$model_path" --file "$AUDIO" --threads "$threads" "${extra[@]}"
