#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

grep -Fqx -- 'SOURCE_DIR=/pool/cache/whisper/source' "$ROOT_DIR/.env.example"
grep -Fqx -- 'BUILD_DIR=/pool/build/whisper/host-native' "$ROOT_DIR/.env.example"
grep -Fqx -- 'OUTPUT_DIR=/pool/build/whisper/output' "$ROOT_DIR/.env.example"
grep -Fqx -- 'MODEL_DIR=/pool/cache/whisper/models' "$ROOT_DIR/.env.example"
grep -Fqx -- 'SCCACHE_DIR=/pool/cache/whisper/sccache' "$ROOT_DIR/.env.example"
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
printf 'SCCACHE_DIR=%s\n' "${SCCACHE_DIR:-}" >"$FAKE_CMAKE_ENV"
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
grep -Fqx -- "SCCACHE_DIR=$sccache_dir" "$cmake_env_file"
