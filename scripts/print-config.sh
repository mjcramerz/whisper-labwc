#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
validate_common_config

printf '%-28s %s\n' 'Setting' 'Value'
printf '%-28s %s\n' '----------------------------' '----------------------------------------------------------'
printf '%-28s %s\n' 'Source repository' "$WHISPER_CPP_REPO"
printf '%-28s %s\n' 'Source ref' "$WHISPER_CPP_REF"
printf '%-28s %s\n' 'Source directory' "$SOURCE_DIR_ABS"
printf '%-28s %s\n' 'Build directory' "$BUILD_DIR_ABS"
printf '%-28s %s\n' 'Output directory' "$OUTPUT_DIR_ABS"
printf '%-28s %s\n' 'Model directory' "$MODEL_DIR_ABS"
printf '%-28s %s\n' 'Generator configured' "$BUILDER_CMAKE_GENERATOR"
printf '%-28s %s\n' 'Generator effective' "$(choose_generator)"
printf '%-28s %s\n' 'Build jobs' "$BUILD_JOBS"
printf '%-28s %s\n' 'Backend' "$(accelerator_label)"
printf '%-28s %s\n' 'C Release flags' "$(effective_c_flags)"
printf '%-28s %s\n' 'C++ Release flags' "$(effective_cxx_flags)"
printf '%-28s %s\n' 'LTO / OpenMP / ccache' "$ENABLE_LTO / $ENABLE_OPENMP / $ENABLE_CCACHE"
printf '%-28s %s\n' 'CPU repack / fast math' "$ENABLE_CPU_REPACK / $ENABLE_FAST_MATH"
printf '%-28s %s\n' 'BLAS / vendor' "$ENABLE_BLAS / $BLAS_VENDOR"
printf '%-28s %s\n' 'CUDA / architectures' "$ENABLE_CUDA / $CUDA_ARCHS"
printf '%-28s %s\n' 'HIP / targets' "$ENABLE_HIP / $AMDGPU_TARGETS"
printf '%-28s %s\n' 'Vulkan' "$ENABLE_VULKAN"
printf '%-28s %s\n' 'SYCL / target / arch' "$ENABLE_SYCL / $SYCL_TARGET / ${SYCL_DEVICE_ARCH:-auto}"
printf '%-28s %s\n' 'OpenVINO / FFmpeg' "$ENABLE_OPENVINO / $ENABLE_FFMPEG"
printf '%-28s %s\n' 'Offline / source update' "$OFFLINE / $SOURCE_UPDATE"
printf '%-28s %s\n' 'Allow external directories' "$ALLOW_EXTERNAL_DIRS"
