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

mapfile -t targets < <(enabled_binary_names)
((${#targets[@]} > 0)) || die "No executable targets are enabled"
prepare_sccache_dir
prepare_cuda_glibc_compat

jobs="$(build_jobs)"
log "Building ${targets[*]} with $jobs parallel job(s)"
cmake --build "$BUILD_DIR_ABS" --target "${targets[@]}" --parallel "$jobs" --config Release

declare -A built_binaries=()
for name in "${targets[@]}"; do
    candidates=(
        "$BUILD_DIR_ABS/bin/$name"
        "$BUILD_DIR_ABS/bin/Release/$name"
        "$BUILD_DIR_ABS/Release/$name"
    )
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            built_binaries["$name"]="$candidate"
            break
        fi
    done
    [[ -n "${built_binaries[$name]:-}" ]] \
        || die "$name target built, but the executable was not found under $BUILD_DIR_ABS"
done

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

tmp_binaries=()
cleanup() {
    local tmp_binary
    for tmp_binary in "${tmp_binaries[@]}"; do
        rm -f -- "$tmp_binary"
    done
}
trap cleanup EXIT

for name in "${targets[@]}"; do
    tmp_binary="$OUTPUT_DIR_ABS/bin/.$name.tmp.$$"
    tmp_binaries+=("$tmp_binary")
    install -m 0755 "${built_binaries[$name]}" "$tmp_binary"
    if [[ "$STRIP_BINARY" == "1" ]] && command -v strip >/dev/null 2>&1; then
        strip --strip-unneeded "$tmp_binary" 2>/dev/null \
            || warn "strip could not process $name; keeping symbols"
    fi
done

for name in "${targets[@]}"; do
    mv -f -- "$OUTPUT_DIR_ABS/bin/.$name.tmp.$$" "$OUTPUT_DIR_ABS/bin/$name"
    ln -sfn "bin/$name" "$OUTPUT_DIR_ABS/$name"
done
for name in whisper-cli whisper-server; do
    if [[ ! " ${targets[*]} " =~ [[:space:]]${name}[[:space:]] ]]; then
        rm -f -- "$OUTPUT_DIR_ABS/bin/$name" "$OUTPUT_DIR_ABS/$name"
    fi
done

if [[ -f "$SOURCE_DIR_ABS/LICENSE" ]]; then
    install -m 0644 "$SOURCE_DIR_ABS/LICENSE" "$OUTPUT_DIR_ABS/metadata/WHISPER_CPP_LICENSE"
fi
if [[ -f "$BUILD_DIR_ABS/compile_commands.json" ]]; then
    cp -f -- "$BUILD_DIR_ABS/compile_commands.json" "$OUTPUT_DIR_ABS/metadata/compile_commands.json"
fi
if [[ -f "$BUILD_DIR_ABS/cmake-command.txt" ]]; then
    cp -f -- "$BUILD_DIR_ABS/cmake-command.txt" "$OUTPUT_DIR_ABS/metadata/cmake-command.txt"
fi

checksums_tmp="$OUTPUT_DIR_ABS/metadata/.SHA256SUMS.tmp.$$"
: >"$checksums_tmp"
for name in "${targets[@]}"; do
    checksum="$(sha256sum "$OUTPUT_DIR_ABS/bin/$name" | awk '{print $1}')"
    printf '%s  bin/%s\n' "$checksum" "$name" >>"$checksums_tmp"
done
mv -f -- "$checksums_tmp" "$OUTPUT_DIR_ABS/metadata/SHA256SUMS"

commit="$(git -C "$SOURCE_DIR_ABS" rev-parse HEAD 2>/dev/null || printf unknown)"
cc="$(selected_cc)"
cxx="$(selected_cxx)"
cc_path="$(canonical_command "$cc" || printf '%s' "$cc")"
cxx_path="$(canonical_command "$cxx" || printf '%s' "$cxx")"
cuda_archs='disabled'
amd_targets='disabled'
[[ "$ENABLE_CUDA" == "1" ]] && cuda_archs="$(detect_cuda_archs || printf unknown)"
[[ "$ENABLE_HIP" == "1" ]] && amd_targets="$(detect_amd_targets || printf unknown)"
targets_csv="$(IFS=,; printf '%s' "${targets[*]}")"

{
    printf 'built_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'build_profile=%s\n' "$BUILD_PROFILE"
    printf 'build_targets=%s\n' "$targets_csv"
    printf 'source_repo=%s\n' "$WHISPER_CPP_REPO"
    printf 'source_ref=%s\n' "$WHISPER_CPP_REF"
    printf 'source_commit=%s\n' "$commit"
    printf 'host=%s\n' "$(uname -a)"
    printf 'backend=%s\n' "$(accelerator_label)"
    printf 'c_flags=%s\n' "$CMAKE_C_FLAGS"
    printf 'cxx_flags=%s\n' "$CMAKE_CXX_FLAGS"
    printf 'cuda_flags=%s\n' "$CMAKE_CUDA_FLAGS"
    printf 'c_flags_release=%s\n' "$(effective_c_flags)"
    printf 'cxx_flags_release=%s\n' "$(effective_cxx_flags)"
    printf 'cuda_flags_release=%s\n' "$(effective_cuda_flags)"
    printf 'c_compiler=%s\n' "$($cc_path --version 2>/dev/null | head -n1)"
    printf 'cxx_compiler=%s\n' "$($cxx_path --version 2>/dev/null | head -n1)"
    if [[ "$ENABLE_CUDA" == "1" ]]; then
        cuda="$(selected_cuda)"
        cuda_path="$(canonical_command "$cuda" || printf '%s' "$cuda")"
        cuda_host="$(selected_cuda_host)"
        cuda_host_path="$(canonical_command "$cuda_host" || printf '%s' "$cuda_host")"
        printf 'cuda_compiler=%s\n' "$($cuda_path --version 2>/dev/null | tail -n1)"
        printf 'cuda_host_compiler=%s\n' "$($cuda_host_path --version 2>/dev/null | head -n1)"
    fi
    printf 'cmake=%s\n' "$(cmake --version | head -n1)"
    printf 'build_jobs=%s\n' "$jobs"
    printf 'ggml_native=%s\n' "$GGML_NATIVE"
    printf 'lto=%s\n' "$ENABLE_LTO"
    printf 'compiler_cache=%s\n' "$(cache_launcher_label)"
    if sccache_enabled || cuda_sccache_enabled; then
        printf 'sccache_dir=%s\n' "$SCCACHE_DIR_ABS"
        printf 'sccache_server_uds=%s\n' "${SCCACHE_SERVER_UDS_ABS:-}"
    fi
    printf 'openmp=%s\n' "$ENABLE_OPENMP"
    printf 'cpu_repack=%s\n' "$ENABLE_CPU_REPACK"
    printf 'fast_math=%s\n' "$ENABLE_FAST_MATH"
    printf 'blas=%s\n' "$ENABLE_BLAS"
    printf 'blas_vendor=%s\n' "$BLAS_VENDOR"
    printf 'cuda=%s\n' "$ENABLE_CUDA"
    printf 'cuda_architectures=%s\n' "$cuda_archs"
    printf 'cuda_flash_attention=%s\n' "$ENABLE_CUDA_FA"
    printf 'cuda_flash_attention_all_quants=%s\n' "$ENABLE_CUDA_FA_ALL_QUANTS"
    printf 'cuda_force_mmq=%s\n' "$CUDA_FORCE_MMQ"
    printf 'cuda_force_cublas=%s\n' "$CUDA_FORCE_CUBLAS"
    printf 'cuda_no_peer_copy=%s\n' "$CUDA_NO_PEER_COPY"
    printf 'cuda_no_vmm=%s\n' "$CUDA_NO_VMM"
    printf 'cuda_graphs=%s\n' "$ENABLE_CUDA_GRAPHS"
    printf 'cuda_nccl=%s\n' "$ENABLE_CUDA_NCCL"
    printf 'cuda_compression_mode=%s\n' "$CUDA_COMPRESSION_MODE"
    printf 'cuda_glibc_compatibility=%s\n' "$ENABLE_CUDA_GLIBC_COMPAT"
    if [[ "$ENABLE_CUDA_GLIBC_COMPAT" == "1" ]]; then
        printf 'cuda_glibc_source_header=%s\n' "$CUDA_GLIBC_HEADER_ABS"
        printf 'cuda_glibc_private_overlay=%s\n' "$CUDA_GLIBC_PATCHED_HEADER_ABS"
    fi
    printf 'hip=%s\n' "$ENABLE_HIP"
    printf 'amdgpu_targets=%s\n' "$amd_targets"
    printf 'vulkan=%s\n' "$ENABLE_VULKAN"
    printf 'sycl=%s\n' "$ENABLE_SYCL"
    printf 'sycl_target=%s\n' "$SYCL_TARGET"
    printf 'sycl_device_arch=%s\n' "${SYCL_DEVICE_ARCH:-auto}"
    printf 'openvino=%s\n' "$ENABLE_OPENVINO"
    printf 'ffmpeg=%s\n' "$ENABLE_FFMPEG"
    if [[ "$BUILD_CLI" == "1" ]]; then
        cli_sha="$(sha256sum "$OUTPUT_DIR_ABS/bin/whisper-cli" | awk '{print $1}')"
        printf 'binary_sha256=%s\n' "$cli_sha"
        printf 'whisper_cli_sha256=%s\n' "$cli_sha"
    fi
    if [[ "$BUILD_SERVER" == "1" ]]; then
        server_sha="$(sha256sum "$OUTPUT_DIR_ABS/bin/whisper-server" | awk '{print $1}')"
        printf 'whisper_server_sha256=%s\n' "$server_sha"
    fi
} >"$OUTPUT_DIR_ABS/metadata/build-info.txt"

rm -f -- "$OUTPUT_DIR_ABS/metadata/file-whisper-cli.txt" \
    "$OUTPUT_DIR_ABS/metadata/file-whisper-server.txt" \
    "$OUTPUT_DIR_ABS/metadata/ldd-whisper-cli.txt" \
    "$OUTPUT_DIR_ABS/metadata/ldd-whisper-server.txt"
for name in "${targets[@]}"; do
    if command -v file >/dev/null 2>&1; then
        file "$OUTPUT_DIR_ABS/bin/$name" >"$OUTPUT_DIR_ABS/metadata/file-$name.txt"
    fi
    if command -v ldd >/dev/null 2>&1; then
        ldd "$OUTPUT_DIR_ABS/bin/$name" >"$OUTPUT_DIR_ABS/metadata/ldd-$name.txt" 2>&1 || true
    fi
    info "Staged binary: $OUTPUT_DIR_ABS/bin/$name"
done
