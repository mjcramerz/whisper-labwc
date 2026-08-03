#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT_DIR="${ROOT_DIR:-$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)}"
ROOT_DIR="$(cd -- "$ROOT_DIR" >/dev/null 2>&1 && pwd -P)"

# Direct script invocation reads .env. Make exports the already-resolved values
# and sets CONFIG_FROM_MAKE=1 so command-line overrides remain authoritative.
if [[ "${CONFIG_FROM_MAKE:-0}" != "1" && -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    set +a
fi

: "${WHISPER_CPP_REPO:=https://github.com/ggml-org/whisper.cpp.git}"
: "${WHISPER_CPP_REF:=v1.9.1}"
: "${SOURCE_DIR:=.cache/whisper.cpp}"
: "${BUILD_DIR:=.build/native}"
: "${OUTPUT_DIR:=output}"
: "${MODEL_DIR:=output/models}"
# CMAKE_GENERATOR is also a special CMake environment variable. Capture the
# wrapper setting, then remove it from the environment so the literal value
# "auto" is never interpreted by CMake as a generator name.
: "${CMAKE_GENERATOR:=auto}"
BUILDER_CMAKE_GENERATOR="$CMAKE_GENERATOR"
unset CMAKE_GENERATOR
: "${BUILD_JOBS:=auto}"
: "${CMAKE_C_COMPILER:=}"
: "${CMAKE_CXX_COMPILER:=}"
: "${GGML_NATIVE:=1}"
: "${ENABLE_LTO:=1}"
: "${ENABLE_CCACHE:=1}"
: "${ENABLE_OPENMP:=1}"
: "${ENABLE_CPU_REPACK:=1}"
: "${ENABLE_FAST_MATH:=0}"
: "${ENABLE_BLAS:=0}"
: "${BLAS_VENDOR:=OpenBLAS}"
: "${ENABLE_CUDA:=0}"
: "${CUDA_ARCHS:=auto}"
: "${ENABLE_CUDA_FA:=1}"
: "${CUDA_FORCE_MMQ:=0}"
: "${CUDA_FORCE_CUBLAS:=0}"
: "${ENABLE_HIP:=0}"
: "${AMDGPU_TARGETS:=auto}"
: "${ENABLE_VULKAN:=0}"
: "${ENABLE_SYCL:=0}"
: "${ENABLE_SYCL_F16:=0}"
: "${SYCL_TARGET:=INTEL}"
: "${SYCL_DEVICE_ARCH:=}"
: "${ENABLE_OPENVINO:=0}"
: "${ENABLE_FFMPEG:=0}"
: "${STRIP_BINARY:=1}"
: "${OFFLINE:=0}"
: "${SOURCE_UPDATE:=0}"
: "${FORCE_SOURCE_RESET:=0}"
: "${HF_TOKEN:=}"
: "${STRICT_RESOURCES:=0}"
: "${FORCE_DOWNLOAD:=0}"
: "${ALLOW_EXTERNAL_DIRS:=0}"
: "${RUNTIME_THREADS:=auto}"
: "${EXTRA_CMAKE_ARGS:=}"
: "${EXTRA_C_FLAGS:=}"
: "${EXTRA_CXX_FLAGS:=}"

resolve_path() {
    local path=$1 joined
    if [[ "$path" = /* ]]; then
        joined="$path"
    else
        joined="$ROOT_DIR/$path"
    fi
    if command -v realpath >/dev/null 2>&1; then
        realpath -m -- "$joined"
    else
        printf '%s\n' "$joined"
    fi
}

SOURCE_DIR_ABS="$(resolve_path "$SOURCE_DIR")"
BUILD_DIR_ABS="$(resolve_path "$BUILD_DIR")"
OUTPUT_DIR_ABS="$(resolve_path "$OUTPUT_DIR")"
MODEL_DIR_ABS="$(resolve_path "$MODEL_DIR")"
MANIFEST_PATH="$ROOT_DIR/models/models.tsv"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;36m  ->\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_bool() {
    local name=$1 value=${!1:-}
    case "$value" in
        0|1) ;;
        *) die "$name must be 0 or 1, got: '$value'" ;;
    esac
}

cmake_bool() {
    local value=$1
    [[ "$value" == "1" ]] && printf 'ON\n' || printf 'OFF\n'
}

paths_overlap() {
    local first=${1%/} second=${2%/}
    [[ "$first" == "$second" || "$first" == "$second/"* || "$second" == "$first/"* ]]
}

version_at_least() {
    local actual=$1 required=$2
    [[ "$(printf '%s\n%s\n' "$required" "$actual" | sort -V | head -n1)" == "$required" ]]
}

safe_remove_path() {
    local path=${1:-} label=${2:-path}
    [[ -n "$path" && "$path" != "/" && "$path" != "$ROOT_DIR" && "$path" != "${HOME:-/__no_home__}" ]] \
        || die "Refusing to remove unsafe $label: '$path'"
    if [[ "$ALLOW_EXTERNAL_DIRS" == "0" && "$path" != "$ROOT_DIR/"* ]]; then
        die "Refusing to remove external $label while ALLOW_EXTERNAL_DIRS=0: $path"
    fi
}

validate_common_config() {
    local name
    for name in GGML_NATIVE ENABLE_LTO ENABLE_CCACHE ENABLE_OPENMP ENABLE_CPU_REPACK \
                ENABLE_FAST_MATH ENABLE_BLAS ENABLE_CUDA ENABLE_CUDA_FA CUDA_FORCE_MMQ \
                CUDA_FORCE_CUBLAS ENABLE_HIP ENABLE_VULKAN ENABLE_SYCL ENABLE_SYCL_F16 \
                ENABLE_OPENVINO ENABLE_FFMPEG STRIP_BINARY OFFLINE SOURCE_UPDATE \
                FORCE_SOURCE_RESET STRICT_RESOURCES FORCE_DOWNLOAD ALLOW_EXTERNAL_DIRS; do
        validate_bool "$name"
    done

    [[ -n "$WHISPER_CPP_REPO" ]] || die "WHISPER_CPP_REPO cannot be empty"
    [[ -n "$WHISPER_CPP_REF" ]] || die "WHISPER_CPP_REF cannot be empty"
    [[ -n "$BLAS_VENDOR" ]] || die "BLAS_VENDOR cannot be empty"

    local backends=$((ENABLE_CUDA + ENABLE_HIP + ENABLE_VULKAN + ENABLE_SYCL))
    if (( backends > 1 )); then
        die "Enable at most one primary GPU backend among CUDA, HIP, Vulkan, and SYCL per build directory"
    fi
    if [[ "$CUDA_FORCE_MMQ" == "1" && "$CUDA_FORCE_CUBLAS" == "1" ]]; then
        die "CUDA_FORCE_MMQ and CUDA_FORCE_CUBLAS are mutually exclusive"
    fi
    if [[ "$ENABLE_SYCL_F16" == "1" && "$ENABLE_SYCL" != "1" ]]; then
        die "ENABLE_SYCL_F16=1 requires ENABLE_SYCL=1"
    fi

    local label path
    for label in SOURCE_DIR BUILD_DIR OUTPUT_DIR MODEL_DIR; do
        case "$label" in
            SOURCE_DIR) path="$SOURCE_DIR_ABS" ;;
            BUILD_DIR)  path="$BUILD_DIR_ABS" ;;
            OUTPUT_DIR) path="$OUTPUT_DIR_ABS" ;;
            MODEL_DIR)  path="$MODEL_DIR_ABS" ;;
        esac
        [[ -n "$path" && "$path" != "/" && "$path" != "$ROOT_DIR" ]] \
            || die "$label resolves to an unsafe path: $path"
        if [[ "$ALLOW_EXTERNAL_DIRS" == "0" && "$path" != "$ROOT_DIR/"* ]]; then
            die "$label must remain under ROOT_DIR unless ALLOW_EXTERNAL_DIRS=1: $path"
        fi
    done

    # Source, build, and output trees must be independent. MODEL_DIR may be a
    # child of OUTPUT_DIR, which is the default and intentional layout.
    paths_overlap "$SOURCE_DIR_ABS" "$BUILD_DIR_ABS" && die "SOURCE_DIR and BUILD_DIR must not overlap"
    paths_overlap "$SOURCE_DIR_ABS" "$OUTPUT_DIR_ABS" && die "SOURCE_DIR and OUTPUT_DIR must not overlap"
    paths_overlap "$BUILD_DIR_ABS" "$OUTPUT_DIR_ABS" && die "BUILD_DIR and OUTPUT_DIR must not overlap"
    paths_overlap "$SOURCE_DIR_ABS" "$MODEL_DIR_ABS" && die "SOURCE_DIR and MODEL_DIR must not overlap"
    paths_overlap "$BUILD_DIR_ABS" "$MODEL_DIR_ABS" && die "BUILD_DIR and MODEL_DIR must not overlap"
    if paths_overlap "$OUTPUT_DIR_ABS" "$MODEL_DIR_ABS" \
        && [[ "$MODEL_DIR_ABS" != "$OUTPUT_DIR_ABS" && "$MODEL_DIR_ABS" != "$OUTPUT_DIR_ABS/"* ]]; then
        die "When OUTPUT_DIR and MODEL_DIR overlap, MODEL_DIR must be OUTPUT_DIR itself or one of its children"
    fi
    return 0
}

logical_cores() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    else
        getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n'
    fi
}

physical_cores() {
    if command -v lscpu >/dev/null 2>&1; then
        local count logical
        count="$(lscpu -p=CORE,SOCKET 2>/dev/null | awk -F, '!/^#/ {print $1 "," $2}' | sort -u | wc -l | tr -d ' ')"
        logical="$(logical_cores)"
        if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
            (( count > logical )) && count=$logical
            printf '%s\n' "$count"
            return
        fi
    fi
    logical_cores
}

build_jobs() {
    if [[ "$BUILD_JOBS" == "auto" || -z "$BUILD_JOBS" ]]; then
        logical_cores
    elif [[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "$BUILD_JOBS"
    else
        die "BUILD_JOBS must be 'auto' or a positive integer"
    fi
}

selected_cxx() {
    if [[ -n "$CMAKE_CXX_COMPILER" ]]; then
        printf '%s\n' "$CMAKE_CXX_COMPILER"
    elif [[ "$ENABLE_SYCL" == "1" ]] && command -v icpx >/dev/null 2>&1; then
        command -v icpx
    else
        command -v c++ 2>/dev/null || printf 'c++\n'
    fi
}

selected_cc() {
    if [[ -n "$CMAKE_C_COMPILER" ]]; then
        printf '%s\n' "$CMAKE_C_COMPILER"
    elif [[ "$ENABLE_SYCL" == "1" ]] && command -v icx >/dev/null 2>&1; then
        command -v icx
    else
        command -v cc 2>/dev/null || printf 'cc\n'
    fi
}

native_flags() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64|i?86)
            printf '%s\n' '-march=native -mtune=native'
            ;;
        aarch64|arm64|armv7l|armv8l)
            printf '%s\n' '-mcpu=native'
            ;;
        ppc64|ppc64le)
            printf '%s\n' '-mcpu=native -mtune=native'
            ;;
        riscv64)
            printf '%s\n' '-march=native -mtune=native'
            ;;
        *)
            printf '\n'
            ;;
    esac
}

effective_native_flags() {
    if [[ "$GGML_NATIVE" == "1" ]]; then
        native_flags
    else
        printf '\n'
    fi
}

fast_math_flags() {
    if [[ "$ENABLE_FAST_MATH" == "1" ]]; then
        printf '%s\n' '-ffast-math -fno-math-errno -fno-trapping-math'
    else
        printf '\n'
    fi
}

effective_release_flags() {
    local extra=${1:-} flags='-O3 -DNDEBUG' value
    value="$(effective_native_flags)"
    [[ -n "$value" ]] && flags+=" $value"
    value="$(fast_math_flags)"
    [[ -n "$value" ]] && flags+=" $value"
    [[ -n "$extra" ]] && flags+=" $extra"
    printf '%s\n' "$flags"
}

effective_c_flags() {
    effective_release_flags "$EXTRA_C_FLAGS"
}

effective_cxx_flags() {
    effective_release_flags "$EXTRA_CXX_FLAGS"
}

choose_generator() {
    if [[ "$BUILDER_CMAKE_GENERATOR" == "auto" || -z "$BUILDER_CMAKE_GENERATOR" ]]; then
        if command -v ninja >/dev/null 2>&1; then
            printf 'Ninja\n'
        else
            printf 'Unix Makefiles\n'
        fi
    else
        printf '%s\n' "$BUILDER_CMAKE_GENERATOR"
    fi
}

canonical_command() {
    local value path
    value=${1:-}
    [[ -n "$value" ]] || return 1
    path="$(command -v -- "$value" 2>/dev/null || true)"
    [[ -n "$path" ]] || return 1
    if command -v realpath >/dev/null 2>&1; then
        realpath -e -- "$path" 2>/dev/null || printf '%s\n' "$path"
    else
        printf '%s\n' "$path"
    fi
}

detect_cuda_archs() {
    if [[ "$CUDA_ARCHS" != "auto" && -n "$CUDA_ARCHS" ]]; then
        printf '%s\n' "$CUDA_ARCHS"
        return 0
    fi

    command -v nvidia-smi >/dev/null 2>&1 || return 1
    local caps
    caps="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
        | awk -F. 'NF >= 2 {gsub(/[^0-9]/, "", $1); gsub(/[^0-9]/, "", $2); if ($1 != "" && $2 != "") print $1 $2}' \
        | sort -u | paste -sd ';' -)"
    [[ -n "$caps" ]] || return 1
    printf '%s\n' "$caps"
}

detect_amd_targets() {
    if [[ "$AMDGPU_TARGETS" != "auto" && -n "$AMDGPU_TARGETS" ]]; then
        printf '%s\n' "$AMDGPU_TARGETS"
        return 0
    fi

    local targets=''
    if command -v rocm_agent_enumerator >/dev/null 2>&1; then
        targets="$(rocm_agent_enumerator -name 2>/dev/null \
            | grep -E '^gfx[0-9a-f]+$' | grep -v '^gfx000$' | sort -u | paste -sd ';' - || true)"
    elif command -v rocminfo >/dev/null 2>&1; then
        targets="$(rocminfo 2>/dev/null \
            | awk '/Name:/ && $2 ~ /^gfx[0-9a-f]+$/ && $2 != "gfx000" {print $2}' \
            | sort -u | paste -sd ';' -)"
    fi
    [[ -n "$targets" ]] || return 1
    printf '%s\n' "$targets"
}

format_params() {
    local value=$1
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    elif (( value >= 1000 )); then
        awk -v v="$value" 'BEGIN {printf "%.2fB", v/1000}'
    else
        printf '%sM' "$value"
    fi
}

format_mib() {
    local mib=$1
    if (( mib >= 1024 )); then
        awk -v v="$mib" 'BEGIN {printf "%.1fGiB", v/1024}'
    else
        printf '%sMiB' "$mib"
    fi
}

available_ram_gib() {
    awk '/MemTotal:/ {printf "%d\n", $2 / 1024 / 1024}' /proc/meminfo 2>/dev/null || printf '0\n'
}

accelerator_label() {
    if [[ "$ENABLE_CUDA" == "1" ]]; then printf 'CUDA'
    elif [[ "$ENABLE_HIP" == "1" ]]; then printf 'HIP/ROCm'
    elif [[ "$ENABLE_VULKAN" == "1" ]]; then printf 'Vulkan'
    elif [[ "$ENABLE_SYCL" == "1" ]]; then printf 'SYCL'
    else printf 'CPU'
    fi
}
