#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

validate_common_config
require_cmd cmake
require_cmd awk
require_cmd realpath
[[ -f "$SOURCE_DIR_ABS/CMakeLists.txt" ]] || die "Source is not ready; run make source"

generator="$(choose_generator)"
build_marker="$BUILD_DIR_ABS/.native-builder-build"

if [[ -e "$BUILD_DIR_ABS" && ! -d "$BUILD_DIR_ABS" ]]; then
    die "BUILD_DIR exists but is not a directory: $BUILD_DIR_ABS"
fi
if [[ -d "$BUILD_DIR_ABS" && ! -f "$build_marker" ]] \
    && [[ -n "$(find "$BUILD_DIR_ABS" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    die "Refusing to configure into an unmarked non-empty BUILD_DIR: $BUILD_DIR_ABS"
fi
mkdir -p "$BUILD_DIR_ABS"
printf 'native whisper.cpp build directory\nroot=%s\n' "$ROOT_DIR" >"$build_marker"

cache_value() {
    local key=$1
    sed -n "s/^${key}:[^=]*=//p" "$BUILD_DIR_ABS/CMakeCache.txt" 2>/dev/null | tail -n1
}

if [[ -f "$BUILD_DIR_ABS/CMakeCache.txt" ]]; then
    old_generator="$(cache_value CMAKE_GENERATOR)"
    if [[ -n "$old_generator" && "$old_generator" != "$generator" ]]; then
        die "BUILD_DIR was generated with '$old_generator', not '$generator'. Run make clean first."
    fi

    old_source="$(cache_value CMAKE_HOME_DIRECTORY)"
    if [[ -n "$old_source" && "$(realpath -m -- "$old_source")" != "$SOURCE_DIR_ABS" ]]; then
        die "BUILD_DIR belongs to source '$old_source', not '$SOURCE_DIR_ABS'. Run make clean first."
    fi
fi

cc="$(selected_cc)"
cxx="$(selected_cxx)"
cc_path="$(canonical_command "$cc" || true)"
cxx_path="$(canonical_command "$cxx" || true)"
[[ -n "$cc_path" ]] || die "C compiler not found: $cc"
[[ -n "$cxx_path" ]] || die "C++ compiler not found: $cxx"

if [[ -f "$BUILD_DIR_ABS/CMakeCache.txt" ]]; then
    old_cc="$(cache_value CMAKE_C_COMPILER)"
    old_cxx="$(cache_value CMAKE_CXX_COMPILER)"
    old_cc_canonical="$(realpath -e -- "$old_cc" 2>/dev/null || printf '%s' "$old_cc")"
    old_cxx_canonical="$(realpath -e -- "$old_cxx" 2>/dev/null || printf '%s' "$old_cxx")"
    if [[ -n "$old_cc" && "$old_cc_canonical" != "$cc_path" ]]; then
        die "BUILD_DIR was configured with C compiler '$old_cc', not '$cc_path'. Run make clean first."
    fi
    if [[ -n "$old_cxx" && "$old_cxx_canonical" != "$cxx_path" ]]; then
        die "BUILD_DIR was configured with C++ compiler '$old_cxx', not '$cxx_path'. Run make clean first."
    fi
fi

c_flags="$(effective_c_flags)"
cxx_flags="$(effective_cxx_flags)"
cuda_flags="$(effective_cuda_flags)"
prepare_sccache_dir
prepare_cuda_glibc_compat

upstream_ccache="$ENABLE_CCACHE"
if sccache_enabled; then
    upstream_ccache=0
fi

args=(
    -S "$SOURCE_DIR_ABS"
    -B "$BUILD_DIR_ABS"
    -G "$generator"
    -DCMAKE_BUILD_TYPE=Release
    "-DCMAKE_C_COMPILER=$cc_path"
    "-DCMAKE_CXX_COMPILER=$cxx_path"
    "-DCMAKE_C_FLAGS=$CMAKE_C_FLAGS"
    "-DCMAKE_CXX_FLAGS=$CMAKE_CXX_FLAGS"
    "-DCMAKE_C_FLAGS_RELEASE=$c_flags"
    "-DCMAKE_CXX_FLAGS_RELEASE=$cxx_flags"
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    -DBUILD_SHARED_LIBS=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_EXAMPLES=ON
    "-DWHISPER_BUILD_SERVER=$(cmake_bool "$BUILD_SERVER")"
    -DWHISPER_FATAL_WARNINGS=OFF
    -DWHISPER_CURL=OFF
    -DWHISPER_SDL2=OFF
    "-DWHISPER_COMMON_FFMPEG=$(cmake_bool "$ENABLE_FFMPEG")"
    "-DWHISPER_OPENVINO=$(cmake_bool "$ENABLE_OPENVINO")"
    "-DGGML_NATIVE=$(cmake_bool "$GGML_NATIVE")"
    "-DGGML_LTO=$(cmake_bool "$ENABLE_LTO")"
    "-DGGML_CCACHE=$(cmake_bool "$upstream_ccache")"
    "-DGGML_OPENMP=$(cmake_bool "$ENABLE_OPENMP")"
    "-DGGML_CPU_REPACK=$(cmake_bool "$ENABLE_CPU_REPACK")"
    -DGGML_CPU=ON
    -DGGML_STATIC=OFF
    -DGGML_BACKEND_DL=OFF
    -DGGML_RPC=OFF
    -DGGML_BUILD_TESTS=OFF
    -DGGML_BUILD_EXAMPLES=OFF
    "-DGGML_BLAS=$(cmake_bool "$ENABLE_BLAS")"
    "-DGGML_BLAS_VENDOR=$BLAS_VENDOR"
    "-DGGML_CUDA=$(cmake_bool "$ENABLE_CUDA")"
    "-DGGML_CUDA_FA=$(cmake_bool "$ENABLE_CUDA_FA")"
    "-DGGML_CUDA_FA_ALL_QUANTS=$(cmake_bool "$ENABLE_CUDA_FA_ALL_QUANTS")"
    "-DGGML_CUDA_FORCE_MMQ=$(cmake_bool "$CUDA_FORCE_MMQ")"
    "-DGGML_CUDA_FORCE_CUBLAS=$(cmake_bool "$CUDA_FORCE_CUBLAS")"
    "-DGGML_CUDA_NO_PEER_COPY=$(cmake_bool "$CUDA_NO_PEER_COPY")"
    "-DGGML_CUDA_NO_VMM=$(cmake_bool "$CUDA_NO_VMM")"
    "-DGGML_CUDA_GRAPHS=$(cmake_bool "$ENABLE_CUDA_GRAPHS")"
    "-DGGML_CUDA_NCCL=$(cmake_bool "$ENABLE_CUDA_NCCL")"
    "-DGGML_CUDA_COMPRESSION_MODE=$CUDA_COMPRESSION_MODE"
    "-DGGML_HIP=$(cmake_bool "$ENABLE_HIP")"
    "-DGGML_VULKAN=$(cmake_bool "$ENABLE_VULKAN")"
    "-DGGML_SYCL=$(cmake_bool "$ENABLE_SYCL")"
    "-DGGML_SYCL_F16=$(cmake_bool "$ENABLE_SYCL_F16")"
    "-DGGML_SYCL_TARGET=$SYCL_TARGET"
)

if sccache_enabled; then
    args+=(
        "-DCMAKE_C_COMPILER_LAUNCHER=$CMAKE_C_COMPILER_LAUNCHER"
        "-DCMAKE_CXX_COMPILER_LAUNCHER=$CMAKE_CXX_COMPILER_LAUNCHER"
    )
fi

if [[ "$ENABLE_CUDA" == "1" ]]; then
    cuda="$(selected_cuda)"
    cuda_path="$(canonical_command "$cuda" || true)"
    [[ -n "$cuda_path" ]] || die "CUDA compiler not found: $cuda"
    cuda_host="$(selected_cuda_host)"
    cuda_host_path="$(canonical_command "$cuda_host" || true)"
    [[ -n "$cuda_host_path" ]] || die "CUDA host compiler not found: $cuda_host"
    cuda_archs="$(detect_cuda_archs || true)"
    [[ -n "$cuda_archs" ]] \
        || die "Could not determine a host CUDA architecture. Set CUDA_ARCHS explicitly."
    cmake_cuda_compiler="$cuda_path"
    cmake_cuda_launcher="$CMAKE_CUDA_COMPILER_LAUNCHER"
    if [[ "$ENABLE_CUDA_GLIBC_COMPAT" == "1" ]]; then
        cmake_cuda_compiler="$ROOT_DIR/scripts/cuda-compat-nvcc.sh"
        cmake_cuda_launcher=''
        unset CMAKE_CUDA_COMPILER_LAUNCHER
    fi
    args+=(
        "-DCMAKE_CUDA_COMPILER=$cmake_cuda_compiler"
        "-DCMAKE_CUDA_HOST_COMPILER=$cuda_host_path"
        "-DCMAKE_CUDA_FLAGS=$CMAKE_CUDA_FLAGS"
        "-DCMAKE_CUDA_FLAGS_RELEASE=$cuda_flags"
        "-DCMAKE_CUDA_ARCHITECTURES=$cuda_archs"
    )
    if [[ -n "$cmake_cuda_launcher" ]]; then
        args+=("-DCMAKE_CUDA_COMPILER_LAUNCHER=$cmake_cuda_launcher")
    fi
    info "CUDA architectures: $cuda_archs"
fi

if [[ "$ENABLE_HIP" == "1" ]]; then
    amd_targets="$(detect_amd_targets || true)"
    [[ -n "$amd_targets" ]] \
        || die "Could not determine a host AMD GPU target. Set AMDGPU_TARGETS, for example gfx1100."
    args+=("-DAMDGPU_TARGETS=$amd_targets")
    info "AMD GPU targets: $amd_targets"
fi

if [[ "$ENABLE_SYCL" == "1" && -n "$SYCL_DEVICE_ARCH" ]]; then
    args+=("-DGGML_SYCL_DEVICE_ARCH=$SYCL_DEVICE_ARCH")
fi

if [[ -n "$EXTRA_CMAKE_ARGS" ]]; then
    read -r -a extra_args <<<"$EXTRA_CMAKE_ARGS"
    args+=("${extra_args[@]}")
fi

log "Configuring native Release build with $generator"
printf 'cmake' >"$BUILD_DIR_ABS/cmake-command.txt"
printf ' %q' "${args[@]}" >>"$BUILD_DIR_ABS/cmake-command.txt"
printf '\n' >>"$BUILD_DIR_ABS/cmake-command.txt"
cmake "${args[@]}"
info "Configured build directory: $BUILD_DIR_ABS"
