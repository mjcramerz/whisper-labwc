#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

validate_common_config

# Capture a token loaded from .env/Make, then remove the exported variable so
# downloader child processes cannot inherit it through /proc/*/environ or ps e.
hf_token="$HF_TOKEN"
unset HF_TOKEN

for command_name in awk grep stat df od tr sha256sum; do
    require_cmd "$command_name"
done
[[ -r "$MANIFEST_PATH" ]] || die "Model manifest not found: $MANIFEST_PATH"

# Kept global so the EXIT trap can remove a credential-bearing temporary file
# when curl/wget is interrupted before its normal cleanup path runs.
auth_config=''

list_models() {
    printf '\nCurated GGML models (resource figures are practical estimates, not hard limits)\n\n'
    printf '%-3s %-29s %-6s %-7s %-8s %-10s %-8s %-10s\n' '#' 'Model' 'Lang' 'Params' 'File' 'RAM min/rec' 'CPU' 'Weights'
    printf '%-3s %-29s %-6s %-7s %-8s %-10s %-8s %-10s\n' '---' '-----------------------------' '------' '-------' '--------' '----------' '--------' '----------'
    local index=0 previous_family=''
    while IFS=$'\t' read -r id family params_m file_mib min_ram rec_ram cores language precision local_name checksum_algo checksum url notes; do
        [[ -z "$id" || "$id" == \#* || "$id" == "id" ]] && continue
        ((index += 1))
        if [[ -n "$previous_family" && "$family" != "$previous_family" ]]; then
            printf '\n'
        fi
        printf '%-3d %-29s %-6s %-7s %-8s %-10s %-8s %-10s\n' \
            "$index" "$id" "$language" "$(format_params "$params_m")" "$(format_mib "$file_mib")" \
            "${min_ram}/${rec_ram}GiB" "$cores" "$precision"
        previous_family="$family"
    done <"$MANIFEST_PATH"
    printf '\nLegend: .en and every Distil model are English-only; Q5/Q8 are quantized.\n'
    printf 'Use: make download MODEL=base.en   or run plain make download for a prompt.\n\n'
}

lookup_model() {
    local needle=$1 index=0
    while IFS=$'\t' read -r id family params_m file_mib min_ram rec_ram cores language precision local_name checksum_algo checksum url notes; do
        [[ -z "$id" || "$id" == \#* || "$id" == "id" ]] && continue
        ((index += 1))
        if [[ "$needle" == "$id" || "$needle" == "$index" ]]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$id" "$family" "$params_m" "$file_mib" "$min_ram" "$rec_ram" "$cores" "$language" \
                "$precision" "$local_name" "$checksum_algo" "$checksum" "$url" "$notes"
            return 0
        fi
    done <"$MANIFEST_PATH"
    return 1
}

validation_error() {
    warn "$1"
    return 1
}

verify_model_file() {
    local file=$1 algo=$2 checksum=$3 expected_mib=$4
    [[ -f "$file" ]] || validation_error "Model file is missing: $file" || return 1

    local bytes expected_bytes min_bytes max_bytes
    bytes="$(stat -c '%s' "$file" 2>/dev/null || printf 0)"
    [[ "$bytes" =~ ^[0-9]+$ ]] || validation_error "Could not determine model file size" || return 1
    (( bytes > 1048576 )) || validation_error "Model file is unexpectedly small: $bytes bytes" || return 1

    expected_bytes=$((expected_mib * 1024 * 1024))
    min_bytes=$((expected_bytes * 70 / 100))
    max_bytes=$((expected_bytes * 140 / 100))
    if (( bytes < min_bytes || bytes > max_bytes )); then
        validation_error "Model size $bytes bytes is outside the expected range for approximately ${expected_mib} MiB" || return 1
    fi

    if head -c 512 "$file" 2>/dev/null | grep -aEiq '<!doctype|<html|access denied|not found|unauthorized|forbidden'; then
        validation_error "Downloaded content looks like an HTTP error page, not a GGML model" || return 1
    fi

    local magic
    magic="$(od -An -N4 -tx1 "$file" 2>/dev/null | tr -d '[:space:]')"
    case "$magic" in
        6c6d6767|67676d6c) ;;
        *) validation_error "Unexpected model magic bytes '$magic'; expected a whisper.cpp GGML model" || return 1 ;;
    esac

    if [[ "$algo" != "-" && "$checksum" != "-" ]]; then
        local tool="${algo}sum" actual
        command -v "$tool" >/dev/null 2>&1 \
            || validation_error "Checksum tool is unavailable: $tool" || return 1
        actual="$($tool "$file" | awk '{print $1}')"
        [[ "$actual" == "$checksum" ]] \
            || validation_error "$algo checksum mismatch: expected $checksum, got $actual" || return 1
    fi
    return 0
}

validate_token() {
    [[ "$hf_token" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "HF_TOKEN contains unsupported characters; use only letters, digits, dot, underscore, and hyphen"
}

download_with_curl() {
    local url=$1 part=$2 rc=0
    local args=(
        --location --fail --show-error --progress-bar
        --connect-timeout 20
        --retry 6 --retry-delay 3 --retry-all-errors --retry-connrefused
        --continue-at -
        --output "$part"
    )
    if [[ -n "$hf_token" ]]; then
        validate_token
        auth_config="$(mktemp)"
        chmod 0600 "$auth_config"
        printf 'header = "Authorization: Bearer %s"\n' "$hf_token" >"$auth_config"
        args+=(--config "$auth_config")
    fi

    if curl "${args[@]}" "$url"; then rc=0; else rc=$?; fi
    [[ -z "$auth_config" ]] || rm -f -- "$auth_config"
    auth_config=''
    return "$rc"
}

download_with_wget() {
    local url=$1 part=$2 rc=0
    local args=(--continue --tries=6 --timeout=20 --output-document="$part")
    if [[ -n "$hf_token" ]]; then
        validate_token
        auth_config="$(mktemp)"
        chmod 0600 "$auth_config"
        printf 'header = Authorization: Bearer %s\n' "$hf_token" >"$auth_config"
    fi

    if [[ -n "$auth_config" ]]; then
        if WGETRC="$auth_config" wget "${args[@]}" "$url"; then rc=0; else rc=$?; fi
    else
        if wget "${args[@]}" "$url"; then rc=0; else rc=$?; fi
    fi
    [[ -z "$auth_config" ]] || rm -f -- "$auth_config"
    auth_config=''
    return "$rc"
}

prepare_model_directory() {
    local model_marker="$MODEL_DIR_ABS/.native-builder-models"
    local output_marker="$OUTPUT_DIR_ABS/.native-builder-output"

    if [[ -e "$MODEL_DIR_ABS" && ! -d "$MODEL_DIR_ABS" ]]; then
        die "MODEL_DIR exists but is not a directory: $MODEL_DIR_ABS"
    fi
    if [[ -d "$MODEL_DIR_ABS" && ! -f "$model_marker" ]] \
        && [[ -n "$(find "$MODEL_DIR_ABS" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        die "Refusing to manage an unmarked non-empty MODEL_DIR: $MODEL_DIR_ABS"
    fi

    if [[ "$MODEL_DIR_ABS" == "$OUTPUT_DIR_ABS" || "$MODEL_DIR_ABS" == "$OUTPUT_DIR_ABS/"* ]]; then
        if [[ -e "$OUTPUT_DIR_ABS" && ! -d "$OUTPUT_DIR_ABS" ]]; then
            die "OUTPUT_DIR exists but is not a directory: $OUTPUT_DIR_ABS"
        fi
        if [[ -d "$OUTPUT_DIR_ABS" && ! -f "$output_marker" ]] \
            && [[ -n "$(find "$OUTPUT_DIR_ABS" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            die "Refusing to use an unmarked non-empty OUTPUT_DIR: $OUTPUT_DIR_ABS"
        fi
    fi

    mkdir -p "$MODEL_DIR_ABS"
    printf 'native whisper.cpp model directory\nroot=%s\n' "$ROOT_DIR" >"$model_marker"
    if [[ "$MODEL_DIR_ABS" == "$OUTPUT_DIR_ABS" || "$MODEL_DIR_ABS" == "$OUTPUT_DIR_ABS/"* ]]; then
        printf 'native whisper.cpp output directory\nroot=%s\n' "$ROOT_DIR" >"$output_marker"
    fi
}

if [[ "${1:-}" == "--list" ]]; then
    list_models
    exit 0
fi

selection="${MODEL:-${1:-}}"
if [[ -z "$selection" ]]; then
    if ! exec 3<>/dev/tty; then
        die "No interactive terminal. Supply MODEL=<name>, for example MODEL=base.en"
    fi
    list_models >&3
    printf 'Select model by number or name [base.en]: ' >&3
    IFS= read -r selection <&3 || true
    exec 3>&-
    selection="${selection:-base.en}"
fi

record="$(lookup_model "$selection" || true)"
[[ -n "$record" ]] || { list_models >&2; die "Unknown model selection: $selection"; }
IFS=$'\t' read -r id family params_m file_mib min_ram rec_ram cores language precision local_name checksum_algo checksum url notes <<<"$record"
[[ -z "$hf_token" ]] || validate_token

prepare_model_directory
destination="$MODEL_DIR_ABS/$local_name"
part="$destination.part"
mkdir -p "$MODEL_DIR_ABS/.locks"
lock_file="$MODEL_DIR_ABS/.locks/$local_name.lock"
lock_dir=''
cleanup() {
    [[ -z "$auth_config" ]] || rm -f -- "$auth_config"
    [[ -z "$lock_dir" ]] || rm -rf -- "$lock_dir"
}
trap cleanup EXIT

if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock_file"
    flock -n 9 || die "Another download is already using $destination"
else
    lock_dir="$lock_file.d"
    mkdir "$lock_dir" 2>/dev/null || die "Another download is already using $destination"
fi

log "Selected $id"
info "Language: $language | Parameters: $(format_params "$params_m") | Weights: $precision"
info "Approximate file size: $(format_mib "$file_mib") | RAM recommendation: ${min_ram}-${rec_ram} GiB | CPU: $cores cores"
info "$notes"

host_ram="$(available_ram_gib)"
if [[ "$host_ram" =~ ^[0-9]+$ ]] && (( host_ram > 0 && host_ram < min_ram )); then
    message="Host has about ${host_ram} GiB RAM; this model is estimated to need at least ${min_ram} GiB"
    [[ "$STRICT_RESOURCES" == "1" ]] && die "$message" || warn "$message"
fi

if [[ -f "$destination" && "$FORCE_DOWNLOAD" == "0" ]]; then
    if verify_model_file "$destination" "$checksum_algo" "$checksum" "$file_mib"; then
        info "Model already exists and passed validation: $destination"
        exit 0
    fi
    bad="$destination.corrupt.$(date -u +%Y%m%dT%H%M%SZ).$$"
    mv -f -- "$destination" "$bad"
    [[ ! -f "$destination.meta" ]] || mv -f -- "$destination.meta" "$bad.meta"
    warn "Moved the invalid existing model to $bad"
fi

if [[ "$FORCE_DOWNLOAD" == "1" ]]; then
    # Discard only a partial transfer. Keep any completed model in place until
    # its replacement has downloaded and validated successfully.
    rm -f -- "$part"
fi

[[ "$OFFLINE" == "0" ]] || die "OFFLINE=1 and no valid local copy of model '$id' is available"

required_kib=$((file_mib * 1024 + file_mib * 128))
available_kib="$(df -Pk "$MODEL_DIR_ABS" | awk 'NR==2 {print $4}')"
if [[ "$available_kib" =~ ^[0-9]+$ ]] && (( available_kib < required_kib )); then
    die "Insufficient free disk space in $MODEL_DIR_ABS; need roughly $(format_mib "$file_mib") plus download overhead"
fi

log "Downloading to $destination"
if command -v curl >/dev/null 2>&1; then
    download_with_curl "$url" "$part" \
        || die "Download failed; resumable partial data remains at $part"
elif command -v wget >/dev/null 2>&1; then
    download_with_wget "$url" "$part" \
        || die "Download failed; resumable partial data remains at $part"
else
    die "curl or wget is required to download models"
fi

if ! verify_model_file "$part" "$checksum_algo" "$checksum" "$file_mib"; then
    bad="$destination.corrupt.$(date -u +%Y%m%dT%H%M%SZ).$$"
    mv -f -- "$part" "$bad" || true
    die "Validation failed; retained the bad payload as $bad"
fi
mv -f -- "$part" "$destination"

actual_sha256="$(sha256sum "$destination" | awk '{print $1}')"
meta_tmp="$destination.meta.tmp.$$"
{
    printf 'model=%s\n' "$id"
    printf 'downloaded_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source_url=%s\n' "$url"
    printf 'bytes=%s\n' "$(stat -c '%s' "$destination")"
    printf 'published_checksum_algorithm=%s\n' "$checksum_algo"
    printf 'published_checksum=%s\n' "$checksum"
    printf 'local_sha256=%s\n' "$actual_sha256"
} >"$meta_tmp"
mv -f -- "$meta_tmp" "$destination.meta"
chmod 0644 "$destination" "$destination.meta"
info "Downloaded model: $destination"
printf '\nExample:\n  %q -m %q -f /path/to/audio.wav\n\n' "$OUTPUT_DIR_ABS/bin/whisper-cli" "$destination"
