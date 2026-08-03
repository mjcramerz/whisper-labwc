#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

validate_common_config

has_any_marker() {
    local directory=$1
    shift
    local marker
    for marker in "$@"; do
        [[ -e "$directory/$marker" ]] && return 0
    done
    return 1
}

remove_managed_tree() {
    local path=$1 label=$2
    shift 2
    [[ -e "$path" ]] || return 0
    [[ -d "$path" ]] || die "$label is not a directory: $path"
    safe_remove_path "$path" "$label"
    has_any_marker "$path" "$@" \
        || die "Refusing to remove unmarked $label: $path"
    rm -rf -- "$path"
}

guard_source_changes() {
    [[ -d "$SOURCE_DIR_ABS/.git" ]] || return 0
    local changes
    changes="$(git -C "$SOURCE_DIR_ABS" status --porcelain --untracked-files=no 2>/dev/null || true)"
    if [[ -n "$changes" && "$FORCE_SOURCE_RESET" != "1" ]]; then
        printf '%s\n' "$changes" >&2
        die "Managed source has tracked changes. Set FORCE_SOURCE_RESET=1 before deleting it."
    fi
}

remove_output_products() {
    local has_products=0
    [[ -e "$OUTPUT_DIR_ABS/bin" ]] && has_products=1
    [[ -e "$OUTPUT_DIR_ABS/metadata" ]] && has_products=1
    [[ -e "$OUTPUT_DIR_ABS/whisper-cli" || -L "$OUTPUT_DIR_ABS/whisper-cli" ]] && has_products=1
    (( has_products == 0 )) && return 0

    [[ -f "$OUTPUT_DIR_ABS/.native-builder-output" ]] \
        || die "Refusing to clean products from an unmarked OUTPUT_DIR: $OUTPUT_DIR_ABS"
    safe_remove_path "$OUTPUT_DIR_ABS/bin" "staged binary directory"
    safe_remove_path "$OUTPUT_DIR_ABS/metadata" "metadata directory"
    safe_remove_path "$OUTPUT_DIR_ABS/whisper-cli" "staged binary symlink"
    rm -rf -- "${OUTPUT_DIR_ABS:?}/bin" "${OUTPUT_DIR_ABS:?}/metadata"
    rm -f -- "$OUTPUT_DIR_ABS/whisper-cli"
}

mode=${1:-build}
case "$mode" in
    build)
        log "Removing CMake products and staged binary; preserving models and source"
        remove_managed_tree "$BUILD_DIR_ABS" "build directory" .native-builder-build
        remove_output_products
        ;;
    distclean)
        log "Removing build, staged binary, and managed source; preserving models"
        guard_source_changes
        remove_managed_tree "$BUILD_DIR_ABS" "build directory" .native-builder-build
        remove_managed_tree "$SOURCE_DIR_ABS" "source directory" .native-builder-source-dir .native-builder-source
        remove_output_products
        ;;
    purge)
        [[ "${CONFIRM:-}" == "YES" ]] || die "Purge deletes downloaded models. Re-run with: make purge CONFIRM=YES"
        log "Purging managed source, build, output binary, metadata, and models"
        guard_source_changes
        remove_managed_tree "$BUILD_DIR_ABS" "build directory" .native-builder-build
        remove_managed_tree "$SOURCE_DIR_ABS" "source directory" .native-builder-source-dir .native-builder-source

        if [[ "$MODEL_DIR_ABS" != "$OUTPUT_DIR_ABS" && "$MODEL_DIR_ABS" != "$OUTPUT_DIR_ABS/"* ]]; then
            remove_managed_tree "$MODEL_DIR_ABS" "model directory" .native-builder-models
        fi
        remove_managed_tree "$OUTPUT_DIR_ABS" "output directory" .native-builder-output
        ;;
    *)
        die "Unknown clean mode: $mode"
        ;;
esac
