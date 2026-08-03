#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

validate_common_config
require_cmd grep
require_cmd sha256sum

binary="$OUTPUT_DIR_ABS/bin/whisper-cli"
[[ -f "$OUTPUT_DIR_ABS/.native-builder-output" ]] \
    || die "OUTPUT_DIR is not marked as managed: $OUTPUT_DIR_ABS"
[[ -x "$binary" ]] || die "No staged binary found at $binary; run make build"

log "Verifying staged whisper-cli"
if command -v ldd >/dev/null 2>&1; then
    ldd_output="$(ldd "$binary" 2>&1 || true)"
    if grep -q 'not found' <<<"$ldd_output"; then
        printf '%s\n' "$ldd_output" >&2
        die "The staged executable has unresolved dynamic libraries"
    fi
fi

metadata="$OUTPUT_DIR_ABS/metadata/build-info.txt"
if [[ -f "$metadata" ]]; then
    expected_sha="$(sed -n 's/^binary_sha256=//p' "$metadata" | tail -n1)"
    actual_sha="$(sha256sum "$binary" | awk '{print $1}')"
    [[ -z "$expected_sha" || "$expected_sha" == "$actual_sha" ]] \
        || die "Staged binary SHA-256 does not match build metadata"
fi

version_output="$($binary --version 2>&1 || true)"
if [[ -z "$version_output" ]]; then
    version_output="$($binary --help 2>&1 | head -n5 || true)"
fi
[[ -n "$version_output" ]] || die "whisper-cli did not produce version/help output"
printf '%s\n' "$version_output" | head -n5
info "Binary verification passed"
