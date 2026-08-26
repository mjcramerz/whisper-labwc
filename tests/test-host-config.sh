#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

cmp -- "$ROOT_DIR/.env" "$ROOT_DIR/.env.example"
if git -C "$ROOT_DIR" check-ignore -q .env; then
    printf '.env must be tracked, not ignored\n' >&2
    exit 1
fi
git -C "$ROOT_DIR" check-ignore -q .env.local
grep -Fqx -- 'SOURCE_DIR=/pool/cache/whisper-labwc/source' "$ROOT_DIR/.env"
grep -Fqx -- 'MODEL_DIR=/pool/cache/whisper-labwc/models' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_RAM_BUILD_DIR=/pool/build/whisper-labwc/ram' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_RAM_OUTPUT_DIR=/pool/build/whisper-labwc/output/ram' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_RAM_SCCACHE_DIR=/pool/cache/whisper-labwc/sccache/ram' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_RAM_SCCACHE_SERVER_UDS=/pool/cache/whisper-labwc/sccache/ram/server.sock' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_RAM_ARCHIVE_PATH=/pool/build/whisper-labwc/artifacts/whisper-ram.tar.gz' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_BUILD_DIR=/pool/build/whisper-labwc/cuda' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_OUTPUT_DIR=/pool/build/whisper-labwc/output/cuda' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_SCCACHE_DIR=/pool/cache/whisper-labwc/sccache/cuda' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_SCCACHE_SERVER_UDS=/pool/cache/whisper-labwc/sccache/cuda/server.sock' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_ARCHIVE_PATH=/pool/build/whisper-labwc/artifacts/whisper-cuda.tar.gz' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_CUDA_ARCHS=61' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_CMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_CMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-14' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_CMAKE_CUDA_COMPILER_LAUNCHER=' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_CMAKE_CUDA_FLAGS=' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_ENABLE_CUDA_GLIBC_COMPAT=1' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_CUDA_GLIBC_HEADER=/usr/local/cuda-12.8/targets/x86_64-linux/include/crt/math_functions.h' "$ROOT_DIR/.env"
grep -Fqx -- 'WHISPER_CUDA_CUDA_GLIBC_COMPAT_DIR=/pool/cache/whisper-labwc/cuda-compat/12.8' "$ROOT_DIR/.env"
grep -Fqx -- 'CMAKE_C_COMPILER_LAUNCHER=sccache' "$ROOT_DIR/.env.example"
grep -Fqx -- 'CMAKE_CXX_COMPILER_LAUNCHER=sccache' "$ROOT_DIR/.env.example"
grep -Fqx -- 'CMAKE_C_FLAGS=-march=native' "$ROOT_DIR/.env.example"
grep -Fqx -- 'CMAKE_CXX_FLAGS=-march=native' "$ROOT_DIR/.env.example"

fake_bin="$tmp/bin"
args_file="$tmp/cmake-args.txt"
cmake_env_file="$tmp/cmake-env.txt"
source_dir="$tmp/source"
build_dir="$tmp/build"
sccache_dir="$tmp/cache/sccache"
mkdir -p "$fake_bin" "$source_dir"
printf 'cmake_minimum_required(VERSION 3.14)\nproject(fake LANGUAGES C CXX)\n' >"$source_dir/CMakeLists.txt"

cat >"$fake_bin/sccache" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$fake_bin/cmake" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" >"$FAKE_CMAKE_ARGS"
{
    printf 'SCCACHE_DIR=%s\n' "${SCCACHE_DIR:-}"
    printf 'SCCACHE_SERVER_UDS=%s\n' "${SCCACHE_SERVER_UDS:-}"
} >"$FAKE_CMAKE_ENV"
SH
chmod +x "$fake_bin/sccache" "$fake_bin/cmake"

env \
    CONFIG_FROM_MAKE=1 \
    ROOT_DIR="$ROOT_DIR" \
    SOURCE_DIR="$source_dir" \
    BUILD_DIR="$build_dir" \
    OUTPUT_DIR="$tmp/output" \
    MODEL_DIR="$tmp/models" \
    ALLOW_EXTERNAL_DIRS=1 \
    CMAKE_GENERATOR='Unix Makefiles' \
    CMAKE_C_COMPILER_LAUNCHER=sccache \
    CMAKE_CXX_COMPILER_LAUNCHER=sccache \
    CMAKE_C_FLAGS=-march=native \
    CMAKE_CXX_FLAGS=-march=native \
    SCCACHE_DIR="$sccache_dir" \
    SCCACHE_SERVER_UDS="$sccache_dir/server.sock" \
    ENABLE_CCACHE=0 \
    ENABLE_CUDA=0 \
    ENABLE_HIP=0 \
    ENABLE_VULKAN=0 \
    ENABLE_SYCL=0 \
    ENABLE_SYCL_F16=0 \
    FAKE_CMAKE_ARGS="$args_file" \
    FAKE_CMAKE_ENV="$cmake_env_file" \
    PATH="$fake_bin:$PATH" \
    "$ROOT_DIR/scripts/configure.sh" >/dev/null

[[ -d "$sccache_dir" ]]
grep -Fqx -- '-DCMAKE_C_COMPILER_LAUNCHER=sccache' "$args_file"
grep -Fqx -- '-DCMAKE_CXX_COMPILER_LAUNCHER=sccache' "$args_file"
grep -Fqx -- '-DCMAKE_C_FLAGS=-march=native' "$args_file"
grep -Fqx -- '-DCMAKE_CXX_FLAGS=-march=native' "$args_file"
grep -Fqx -- '-DGGML_CCACHE=OFF' "$args_file"
grep -Fqx -- '-DWHISPER_BUILD_SERVER=ON' "$args_file"
grep -Fqx -- '-DGGML_CUDA_NCCL=OFF' "$args_file"
grep -Fqx -- "SCCACHE_DIR=$sccache_dir" "$cmake_env_file"
grep -Fqx -- "SCCACHE_SERVER_UDS=$sccache_dir/server.sock" "$cmake_env_file"

compat_header="$tmp/math_functions.h"
compat_error="$tmp/cuda-compat-error.txt"
: >"$compat_header"
if env \
    CONFIG_FROM_MAKE=1 \
    ROOT_DIR="$ROOT_DIR" \
    SOURCE_DIR="$tmp/compat-source" \
    BUILD_DIR="$tmp/compat-build" \
    OUTPUT_DIR="$tmp/compat-output" \
    MODEL_DIR="$tmp/compat-models" \
    BUILD_PROFILE=cuda \
    ALLOW_EXTERNAL_DIRS=1 \
    CMAKE_C_COMPILER_LAUNCHER=sccache \
    CMAKE_CXX_COMPILER_LAUNCHER=sccache \
    CMAKE_CUDA_COMPILER_LAUNCHER=sccache \
    SCCACHE_DIR="$tmp/compat-sccache" \
    SCCACHE_SERVER_UDS="$tmp/compat-sccache/server.sock" \
    ENABLE_CUDA=1 \
    ENABLE_CUDA_GLIBC_COMPAT=1 \
    CUDA_GLIBC_HEADER="$compat_header" \
    CUDA_GLIBC_COMPAT_DIR="$tmp/cuda-compat" \
    bash -c "source \"\$1\"; validate_common_config" _ "$ROOT_DIR/scripts/lib.sh" \
    >"$compat_error" 2>&1; then
    printf 'CUDA glibc compatibility mode unexpectedly accepted a CUDA compiler launcher\n' >&2
    exit 1
fi
grep -Fq -- 'CMAKE_CUDA_COMPILER_LAUNCHER must be empty when ENABLE_CUDA_GLIBC_COMPAT=1' "$compat_error"
