#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

validate_common_config
require_cmd grep
require_cmd sha256sum

[[ -f "$OUTPUT_DIR_ABS/.native-builder-output" ]] \
    || die "OUTPUT_DIR is not marked as managed: $OUTPUT_DIR_ABS"

mapfile -t targets < <(enabled_binary_names)
((${#targets[@]} > 0)) || die "No executable targets are enabled"

log "Verifying staged ${targets[*]}"
for name in "${targets[@]}"; do
    binary="$OUTPUT_DIR_ABS/bin/$name"
    [[ -x "$binary" ]] || die "No staged $name found at $binary; run the matching build target"
    if command -v ldd >/dev/null 2>&1; then
        ldd_output="$(ldd "$binary" 2>&1 || true)"
        if grep -q 'not found' <<<"$ldd_output"; then
            printf '%s\n' "$ldd_output" >&2
            die "$name has unresolved dynamic libraries"
        fi
    fi
done

checksums="$OUTPUT_DIR_ABS/metadata/SHA256SUMS"
[[ -s "$checksums" ]] || die "Missing staged checksum manifest: $checksums"
(
    cd -- "$OUTPUT_DIR_ABS"
    sha256sum --check --strict metadata/SHA256SUMS
)

metadata="$OUTPUT_DIR_ABS/metadata/build-info.txt"
[[ -s "$metadata" ]] || die "Missing build metadata: $metadata"
metadata_profile="$(sed -n 's/^build_profile=//p' "$metadata" | tail -n1)"
[[ "$metadata_profile" == "$BUILD_PROFILE" ]] \
    || die "Staged metadata profile '$metadata_profile' does not match requested profile '$BUILD_PROFILE'"

for name in "${targets[@]}"; do
    case "$name" in
        whisper-cli) metadata_key=whisper_cli_sha256 ;;
        whisper-server) metadata_key=whisper_server_sha256 ;;
        *) die "Unsupported staged binary name: $name" ;;
    esac
    expected_sha="$(sed -n "s/^${metadata_key}=//p" "$metadata" | tail -n1)"
    actual_sha="$(sha256sum "$OUTPUT_DIR_ABS/bin/$name" | awk '{print $1}')"
    [[ -n "$expected_sha" && "$expected_sha" == "$actual_sha" ]] \
        || die "$name SHA-256 does not match build metadata"
done

if [[ "$BUILD_CLI" == "1" ]]; then
    cli="$OUTPUT_DIR_ABS/bin/whisper-cli"
    version_output="$($cli --version 2>&1 || true)"
    if [[ -z "$version_output" ]]; then
        version_output="$($cli --help 2>&1 | head -n5 || true)"
    fi
    [[ -n "$version_output" ]] || die "whisper-cli did not produce version/help output"
    printf '%s\n' "$version_output" | head -n5
fi
if [[ "$BUILD_SERVER" == "1" ]]; then
    server="$OUTPUT_DIR_ABS/bin/whisper-server"
    if ! server_help="$("$server" --help 2>&1)"; then
        printf '%s\n' "$server_help" | head -n10 >&2
        die "whisper-server --help failed"
    fi
    [[ -n "$server_help" ]] || die "whisper-server did not produce help output"
    info "whisper-server help probe succeeded"
fi
info "Binary verification passed"
