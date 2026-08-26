#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
validate_common_config

printf '%-28s %s\n' 'Setting' 'Value'
printf '%-28s %s\n' '----------------------------' '----------------------------------------------------------'
printf '%-28s %s\n' 'Source repository' "$WHISPER_CPP_REPO"
printf '%-28s %s\n' 'Source ref' "$WHISPER_CPP_REF"
printf '%-28s %s\n' 'Build profile' "$BUILD_PROFILE"
printf '%-28s %s / %s\n' 'Build CLI / server' "$BUILD_CLI" "$BUILD_SERVER"
printf '%-28s %s\n' 'Source directory' "$SOURCE_DIR_ABS"
printf '%-28s %s\n' 'Build directory' "$BUILD_DIR_ABS"
printf '%-28s %s\n' 'Output directory' "$OUTPUT_DIR_ABS"
printf '%-28s %s\n' 'Model directory' "$MODEL_DIR_ABS"
printf '%-28s %s\n' 'Archive path' "${ARCHIVE_PATH_ABS:-disabled}"
printf '%-28s %s\n' 'Generator configured' "$BUILDER_CMAKE_GENERATOR"
printf '%-28s %s\n' 'Generator effective' "$(choose_generator)"
printf '%-28s %s\n' 'Build jobs' "$BUILD_JOBS"
printf '%-28s %s\n' 'Backend' "$(accelerator_label)"
printf '%-28s %s\n' 'CMake C flags' "$CMAKE_C_FLAGS"
printf '%-28s %s\n' 'CMake C++ flags' "$CMAKE_CXX_FLAGS"
printf '%-28s %s\n' 'CMake CUDA flags' "${CMAKE_CUDA_FLAGS:-none}"
printf '%-28s %s\n' 'C Release flags' "$(effective_c_flags)"
printf '%-28s %s\n' 'C++ Release flags' "$(effective_cxx_flags)"
printf '%-28s %s\n' 'CUDA Release flags' "$(effective_cuda_flags)"
printf '%-28s %s\n' 'Compiler cache' "$(cache_launcher_label)"
if sccache_enabled || cuda_sccache_enabled; then
    printf '%-28s %s\n' 'sccache directory' "$SCCACHE_DIR_ABS"
    printf '%-28s %s\n' 'sccache server socket' "${SCCACHE_SERVER_UDS_ABS:-default}"
fi
printf '%-28s %s\n' 'LTO / OpenMP' "$ENABLE_LTO / $ENABLE_OPENMP"
printf '%-28s %s\n' 'CPU repack / fast math' "$ENABLE_CPU_REPACK / $ENABLE_FAST_MATH"
printf '%-28s %s\n' 'BLAS / vendor' "$ENABLE_BLAS / $BLAS_VENDOR"
printf '%-28s %s\n' 'CUDA / architectures' "$ENABLE_CUDA / $CUDA_ARCHS"
printf '%-28s %s\n' 'CUDA compiler / launcher' "${CMAKE_CUDA_COMPILER:-auto} / ${CMAKE_CUDA_COMPILER_LAUNCHER:-none}"
printf '%-28s %s\n' 'CUDA host compiler' "${CMAKE_CUDA_HOST_COMPILER:-auto}"
printf '%-28s %s\n' 'CUDA FA / all quants' "$ENABLE_CUDA_FA / $ENABLE_CUDA_FA_ALL_QUANTS"
printf '%-28s %s\n' 'CUDA force MMQ / cuBLAS' "$CUDA_FORCE_MMQ / $CUDA_FORCE_CUBLAS"
printf '%-28s %s\n' 'CUDA no peer / no VMM' "$CUDA_NO_PEER_COPY / $CUDA_NO_VMM"
printf '%-28s %s\n' 'CUDA graphs / NCCL' "$ENABLE_CUDA_GRAPHS / $ENABLE_CUDA_NCCL"
printf '%-28s %s\n' 'CUDA compression' "$CUDA_COMPRESSION_MODE"
printf '%-28s %s\n' 'CUDA glibc compatibility' "$ENABLE_CUDA_GLIBC_COMPAT"
if [[ "$ENABLE_CUDA_GLIBC_COMPAT" == "1" ]]; then
    printf '%-28s %s\n' 'CUDA installed header' "$CUDA_GLIBC_HEADER_ABS"
    printf '%-28s %s\n' 'CUDA private overlay' "$CUDA_GLIBC_PATCHED_HEADER_ABS"
fi
printf '%-28s %s\n' 'HIP / targets' "$ENABLE_HIP / $AMDGPU_TARGETS"
printf '%-28s %s\n' 'Vulkan' "$ENABLE_VULKAN"
printf '%-28s %s\n' 'SYCL / target / arch' "$ENABLE_SYCL / $SYCL_TARGET / ${SYCL_DEVICE_ARCH:-auto}"
printf '%-28s %s\n' 'OpenVINO / FFmpeg' "$ENABLE_OPENVINO / $ENABLE_FFMPEG"
printf '%-28s %s\n' 'Offline / source update' "$OFFLINE / $SOURCE_UPDATE"
printf '%-28s %s\n' 'Allow external directories' "$ALLOW_EXTERNAL_DIRS"
