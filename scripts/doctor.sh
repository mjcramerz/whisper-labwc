#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

validate_common_config

log "Checking host and toolchain"
[[ "$(uname -s)" == "Linux" ]] || die "This wrapper targets Linux/Debian hosts; detected $(uname -s)"

for command_name in git cmake awk sed grep sort head tail paste tr install realpath sha256sum stat df od; do
    require_cmd "$command_name"
done

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "Neither curl nor wget is installed; make download will be unavailable"
fi

generator="$(choose_generator)"
case "$generator" in
    Ninja*) require_cmd ninja ;;
    "Unix Makefiles") require_cmd make ;;
    *) info "CMake will validate the explicitly selected generator: $generator" ;;
esac

cc="$(selected_cc)"
cxx="$(selected_cxx)"
cc_path="$(canonical_command "$cc" || true)"
cxx_path="$(canonical_command "$cxx" || true)"
[[ -n "$cc_path" ]] || die "C compiler not found: $cc"
[[ -n "$cxx_path" ]] || die "C++ compiler not found: $cxx"

cmake_version="$(cmake --version | awk 'NR==1 {print $3}')"
required_cmake=3.14
[[ "$ENABLE_CUDA" == "1" ]] && required_cmake=3.18
[[ "$ENABLE_HIP" == "1" ]] && required_cmake=3.21
version_at_least "$cmake_version" "$required_cmake" \
    || die "CMake $required_cmake or newer is required for this configuration; found $cmake_version"

os_name="$(. /etc/os-release 2>/dev/null || true; printf '%s' "${PRETTY_NAME:-Linux}")"
info "OS: $os_name $(uname -m)"
info "CMake: $cmake_version | generator: $generator"
info "C compiler: $($cc_path --version 2>/dev/null | head -n1)"
info "C++ compiler: $($cxx_path --version 2>/dev/null | head -n1)"
info "Logical / physical cores: $(logical_cores) / $(physical_cores)"
info "Configured backend: $(accelerator_label)"

tmpdir="$(mktemp -d)"
cleanup() { rm -rf -- "$tmpdir"; }
trap cleanup EXIT

cat >"$tmpdir/probe.c" <<'C'
#include <stdint.h>
int main(void) { volatile uint64_t x = 42; return x == 42 ? 0 : 1; }
C
cat >"$tmpdir/probe.cpp" <<'CPP'
#include <cstdint>
int main() { volatile std::uint64_t x = 42; return x == 42 ? 0 : 1; }
CPP

c_flags="$(effective_c_flags)"
cxx_flags="$(effective_cxx_flags)"
read -r -a c_flag_array <<<"$CMAKE_C_FLAGS $c_flags"
read -r -a cxx_flag_array <<<"$CMAKE_CXX_FLAGS $cxx_flags"

if ! "$cc_path" -std=c11 "${c_flag_array[@]}" -c "$tmpdir/probe.c" -o "$tmpdir/probe-c.o" >/dev/null 2>&1; then
    die "C compiler rejected the configured CMake and Release flags: $CMAKE_C_FLAGS $c_flags"
fi
if ! "$cxx_path" -std=c++17 "${cxx_flag_array[@]}" -c "$tmpdir/probe.cpp" -o "$tmpdir/probe-cxx.o" >/dev/null 2>&1; then
    die "C++ compiler rejected the configured CMake and Release flags: $CMAKE_CXX_FLAGS $cxx_flags"
fi
info "CMake and Release flags accepted: $CMAKE_CXX_FLAGS $cxx_flags"

if [[ "$ENABLE_LTO" == "1" ]]; then
    "$cxx_path" -std=c++17 -O2 -flto "$tmpdir/probe.cpp" -o "$tmpdir/lto-probe" >/dev/null 2>&1 \
        || die "ENABLE_LTO=1 but the selected C++ toolchain cannot compile and link with -flto"
    info "LTO compiler/linker probe succeeded"
fi

if [[ "$ENABLE_OPENMP" == "1" ]]; then
    cat >"$tmpdir/openmp.cpp" <<'CPP'
#include <omp.h>
int main() { return omp_get_max_threads() > 0 ? 0 : 1; }
CPP
    "$cxx_path" -std=c++17 -fopenmp "$tmpdir/openmp.cpp" -o "$tmpdir/openmp-probe" >/dev/null 2>&1 \
        || die "ENABLE_OPENMP=1 but the selected C++ toolchain cannot compile and link OpenMP"
    info "OpenMP compiler/runtime probe succeeded"
fi

if sccache_enabled || cuda_sccache_enabled; then
    require_cmd sccache
    prepare_sccache_dir
    info "CMake compiler launcher: $(cache_launcher_label)"
    info "sccache directory: $SCCACHE_DIR_ABS"
    [[ -n "$SCCACHE_SERVER_UDS_ABS" ]] && info "sccache server socket: $SCCACHE_SERVER_UDS_ABS"
elif [[ "$ENABLE_CCACHE" == "1" ]] && ! command -v ccache >/dev/null 2>&1 && ! command -v sccache >/dev/null 2>&1; then
    warn "ENABLE_CCACHE=1 but neither ccache nor sccache is installed; the build remains valid but uncached"
fi

if [[ "$ENABLE_BLAS" == "1" ]]; then
    case "${BLAS_VENDOR,,}" in
        openblas)
            cat >"$tmpdir/blas.c" <<'C'
#include <cblas.h>
int main(void) { double x = 1.0, y = 2.0; cblas_daxpy(1, 1.0, &x, 1, &y, 1); return y == 3.0 ? 0 : 1; }
C
            "$cc_path" "$tmpdir/blas.c" -lopenblas -o "$tmpdir/blas-probe" >/dev/null 2>&1 \
                || die "ENABLE_BLAS=1 with OpenBLAS requires headers and libraries (Debian: libopenblas-dev)"
            info "OpenBLAS compile/link probe succeeded"
            ;;
        *)
            info "BLAS vendor '$BLAS_VENDOR' selected; CMake will validate its headers and libraries"
            ;;
    esac
fi

if [[ "$ENABLE_FFMPEG" == "1" ]]; then
    require_cmd pkg-config
    for library in libavcodec libavformat libavutil libswresample; do
        pkg-config --exists "$library" || die "ENABLE_FFMPEG=1 requires $library development files"
    done
    info "FFmpeg development libraries found"
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
        || die "Could not detect the installed NVIDIA GPU compute capability. Set CUDA_ARCHS explicitly."

    cat >"$tmpdir/probe.cu" <<'CUDA'
__global__ void probe_kernel() {}
int main() { probe_kernel<<<1, 1>>>(); return 0; }
CUDA
    cuda_arch_args=()
    first_cuda_arch=${cuda_archs%%;*}
    case "$first_cuda_arch" in
        native|all|all-major) ;;
        *-real|*-virtual) first_cuda_arch=${first_cuda_arch%%-*} ;;&
        *)
            [[ "$first_cuda_arch" =~ ^[0-9]+$ ]] \
                || die "CUDA_ARCHS must contain CMake CUDA architecture values, got: '$cuda_archs'"
            cuda_arch_args+=("-arch=sm_$first_cuda_arch")
            ;;
    esac
    cuda_flags="$(effective_cuda_flags)"
    read -r -a cuda_flag_array <<<"$CMAKE_CUDA_FLAGS $cuda_flags"
    cuda_probe_compiler="$cuda_path"
    if [[ "$ENABLE_CUDA_GLIBC_COMPAT" == "1" ]]; then
        prepare_cuda_glibc_compat
        cuda_probe_compiler="$ROOT_DIR/scripts/cuda-compat-nvcc.sh"
    fi
    if ! env CMAKE_CUDA_COMPILER_LAUNCHER= "$cuda_probe_compiler" \
        -ccbin "$cuda_host_path" "${cuda_flag_array[@]}" "${cuda_arch_args[@]}" \
        -c "$tmpdir/probe.cu" -o "$tmpdir/probe-cuda.o" >"$tmpdir/probe-cuda.log" 2>&1; then
        tail -n 40 "$tmpdir/probe-cuda.log" >&2
        die "CUDA compiler rejected host compiler/architecture/flags: $cuda_host_path / $cuda_archs / $CMAKE_CUDA_FLAGS $cuda_flags"
    fi

    info "CUDA toolkit: $($cuda_path --version 2>/dev/null | tail -n1)"
    info "CUDA host compiler: $($cuda_host_path --version 2>/dev/null | head -n1)"
    info "Host CUDA architectures: $cuda_archs"
    info "CUDA architecture/flag probe succeeded"
    if command -v nvidia-smi >/dev/null 2>&1; then
        gpu_summary="$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | paste -sd ';' - || true)"
        [[ -n "$gpu_summary" ]] && info "NVIDIA GPU/driver: $gpu_summary"
    fi
fi

if [[ "$ENABLE_HIP" == "1" ]]; then
    require_cmd hipcc
    amd_targets="$(detect_amd_targets || true)"
    [[ -n "$amd_targets" ]] \
        || die "Could not detect an installed AMD GPU target. Set AMDGPU_TARGETS explicitly, for example gfx1100."
    info "HIP compiler: $(hipcc --version 2>/dev/null | head -n1)"
    info "Host AMD GPU targets: $amd_targets"
fi

if [[ "$ENABLE_VULKAN" == "1" ]]; then
    require_cmd pkg-config
    pkg-config --exists vulkan || die "ENABLE_VULKAN=1 requires Vulkan development files (Debian: libvulkan-dev)"
    if command -v glslc >/dev/null 2>&1; then
        info "Vulkan shader compiler: $(glslc --version 2>/dev/null | head -n1)"
    elif command -v glslangValidator >/dev/null 2>&1; then
        info "Vulkan shader compiler: $(glslangValidator --version 2>/dev/null | head -n1)"
    else
        die "ENABLE_VULKAN=1 requires glslc or glslangValidator to compile shaders"
    fi
    if command -v vulkaninfo >/dev/null 2>&1 && ! vulkaninfo --summary >/dev/null 2>&1; then
        warn "Vulkan development files are present, but vulkaninfo could not enumerate a runtime device"
    fi
fi

if [[ "$ENABLE_SYCL" == "1" ]]; then
    "$cxx_path" -std=c++17 -fsycl "${cxx_flag_array[@]}" "$tmpdir/probe.cpp" -o "$tmpdir/sycl-probe" >/dev/null 2>&1 \
        || die "ENABLE_SYCL=1 requires a working -fsycl compiler, normally Intel oneAPI icpx"
    info "SYCL compiler probe succeeded"
fi

if [[ "$ENABLE_OPENVINO" == "1" ]]; then
    mkdir -p "$tmpdir/openvino-src"
    cat >"$tmpdir/openvino-src/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.14)
project(openvino_probe LANGUAGES CXX)
find_package(OpenVINO REQUIRED COMPONENTS Runtime)
CMAKE
    if ! cmake -S "$tmpdir/openvino-src" -B "$tmpdir/openvino-build" \
        -DCMAKE_BUILD_TYPE=Release >"$tmpdir/openvino.log" 2>&1; then
        tail -n 20 "$tmpdir/openvino.log" >&2
        die "ENABLE_OPENVINO=1 requires an initialized OpenVINO development environment"
    fi
    info "OpenVINO CMake package probe succeeded"
fi

info "Toolchain checks passed"
