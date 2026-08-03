#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

validate_common_config
for command_name in cmake install sha256sum git; do
    require_cmd "$command_name"
done
[[ -f "$BUILD_DIR_ABS/CMakeCache.txt" ]] || die "Build is not configured; run make configure"
[[ -f "$BUILD_DIR_ABS/.native-builder-build" ]] \
    || die "Refusing to use an unmarked build directory: $BUILD_DIR_ABS"

jobs="$(build_jobs)"
log "Building whisper-cli with $jobs parallel job(s)"
cmake --build "$BUILD_DIR_ABS" --target whisper-cli --parallel "$jobs" --config Release

candidates=(
    "$BUILD_DIR_ABS/bin/whisper-cli"
    "$BUILD_DIR_ABS/bin/Release/whisper-cli"
    "$BUILD_DIR_ABS/Release/whisper-cli"
)
binary=''
for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
        binary="$candidate"
        break
    fi
done
[[ -n "$binary" ]] || die "whisper-cli target built, but the executable was not found under $BUILD_DIR_ABS"

output_marker="$OUTPUT_DIR_ABS/.native-builder-output"
if [[ -e "$OUTPUT_DIR_ABS" && ! -d "$OUTPUT_DIR_ABS" ]]; then
    die "OUTPUT_DIR exists but is not a directory: $OUTPUT_DIR_ABS"
fi
if [[ -d "$OUTPUT_DIR_ABS" && ! -f "$output_marker" ]] \
    && [[ -n "$(find "$OUTPUT_DIR_ABS" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    die "Refusing to stage into an unmarked non-empty OUTPUT_DIR: $OUTPUT_DIR_ABS"
fi
mkdir -p "$OUTPUT_DIR_ABS/bin" "$OUTPUT_DIR_ABS/metadata"
printf 'native whisper.cpp output directory\nroot=%s\n' "$ROOT_DIR" >"$output_marker"

tmp_binary="$OUTPUT_DIR_ABS/bin/.whisper-cli.tmp.$$"
cleanup() { rm -f -- "$tmp_binary"; }
trap cleanup EXIT
install -m 0755 "$binary" "$tmp_binary"

if [[ "$STRIP_BINARY" == "1" ]] && command -v strip >/dev/null 2>&1; then
    strip --strip-unneeded "$tmp_binary" 2>/dev/null || warn "strip could not process the binary; keeping symbols"
fi
mv -f "$tmp_binary" "$OUTPUT_DIR_ABS/bin/whisper-cli"
ln -sfn bin/whisper-cli "$OUTPUT_DIR_ABS/whisper-cli"

if [[ -f "$SOURCE_DIR_ABS/LICENSE" ]]; then
    install -m 0644 "$SOURCE_DIR_ABS/LICENSE" "$OUTPUT_DIR_ABS/metadata/WHISPER_CPP_LICENSE"
fi
if [[ -f "$BUILD_DIR_ABS/compile_commands.json" ]]; then
    cp -f "$BUILD_DIR_ABS/compile_commands.json" "$OUTPUT_DIR_ABS/metadata/compile_commands.json"
fi
if [[ -f "$BUILD_DIR_ABS/cmake-command.txt" ]]; then
    cp -f "$BUILD_DIR_ABS/cmake-command.txt" "$OUTPUT_DIR_ABS/metadata/cmake-command.txt"
fi

commit="$(git -C "$SOURCE_DIR_ABS" rev-parse HEAD 2>/dev/null || printf unknown)"
cc="$(selected_cc)"
cxx="$(selected_cxx)"
cc_path="$(canonical_command "$cc" || printf '%s' "$cc")"
cxx_path="$(canonical_command "$cxx" || printf '%s' "$cxx")"
cuda_archs='disabled'
amd_targets='disabled'
[[ "$ENABLE_CUDA" == "1" ]] && cuda_archs="$(detect_cuda_archs || printf unknown)"
[[ "$ENABLE_HIP" == "1" ]] && amd_targets="$(detect_amd_targets || printf unknown)"
binary_sha256="$(sha256sum "$OUTPUT_DIR_ABS/bin/whisper-cli" | awk '{print $1}')"

{
    printf 'built_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source_repo=%s\n' "$WHISPER_CPP_REPO"
    printf 'source_ref=%s\n' "$WHISPER_CPP_REF"
    printf 'source_commit=%s\n' "$commit"
    printf 'host=%s\n' "$(uname -a)"
    printf 'backend=%s\n' "$(accelerator_label)"
    printf 'c_flags_release=%s\n' "$(effective_c_flags)"
    printf 'cxx_flags_release=%s\n' "$(effective_cxx_flags)"
    printf 'c_compiler=%s\n' "$($cc_path --version 2>/dev/null | head -n1)"
    printf 'cxx_compiler=%s\n' "$($cxx_path --version 2>/dev/null | head -n1)"
    printf 'cmake=%s\n' "$(cmake --version | head -n1)"
    printf 'build_jobs=%s\n' "$jobs"
    printf 'ggml_native=%s\n' "$GGML_NATIVE"
    printf 'lto=%s\n' "$ENABLE_LTO"
    printf 'ccache=%s\n' "$ENABLE_CCACHE"
    printf 'openmp=%s\n' "$ENABLE_OPENMP"
    printf 'cpu_repack=%s\n' "$ENABLE_CPU_REPACK"
    printf 'fast_math=%s\n' "$ENABLE_FAST_MATH"
    printf 'blas=%s\n' "$ENABLE_BLAS"
    printf 'blas_vendor=%s\n' "$BLAS_VENDOR"
    printf 'cuda=%s\n' "$ENABLE_CUDA"
    printf 'cuda_architectures=%s\n' "$cuda_archs"
    printf 'hip=%s\n' "$ENABLE_HIP"
    printf 'amdgpu_targets=%s\n' "$amd_targets"
    printf 'vulkan=%s\n' "$ENABLE_VULKAN"
    printf 'sycl=%s\n' "$ENABLE_SYCL"
    printf 'sycl_target=%s\n' "$SYCL_TARGET"
    printf 'sycl_device_arch=%s\n' "${SYCL_DEVICE_ARCH:-auto}"
    printf 'openvino=%s\n' "$ENABLE_OPENVINO"
    printf 'ffmpeg=%s\n' "$ENABLE_FFMPEG"
    printf 'binary_sha256=%s\n' "$binary_sha256"
} >"$OUTPUT_DIR_ABS/metadata/build-info.txt"

if command -v file >/dev/null 2>&1; then
    file "$OUTPUT_DIR_ABS/bin/whisper-cli" >"$OUTPUT_DIR_ABS/metadata/file.txt"
fi
if command -v ldd >/dev/null 2>&1; then
    ldd "$OUTPUT_DIR_ABS/bin/whisper-cli" >"$OUTPUT_DIR_ABS/metadata/ldd.txt" 2>&1 || true
fi

info "Staged binary: $OUTPUT_DIR_ABS/bin/whisper-cli"
