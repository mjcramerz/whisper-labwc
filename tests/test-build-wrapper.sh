#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake="$tmp/fake-upstream"
mkdir -p "$fake"
cat >"$fake/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.14)
project(fake_whisper LANGUAGES C CXX)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
add_executable(whisper-cli main.cpp)
CMAKE
cat >"$fake/main.cpp" <<'CPP'
#include <iostream>
#include <string>
int main(int argc, char ** argv) {
    if (argc > 1 && std::string(argv[1]) == "--version") {
        std::cout << "whisper.cpp fake-test 1.0\n";
        return 0;
    }
    std::cout << "fake whisper-cli\n";
    return 0;
}
CPP
printf 'MIT test license\n' >"$fake/LICENSE"
git -C "$fake" init -q
git -C "$fake" config user.email test@example.invalid
git -C "$fake" config user.name test
git -C "$fake" add .
git -C "$fake" commit -q -m initial
ref="$(git -C "$fake" rev-parse HEAD)"

common_env=(
    CONFIG_FROM_MAKE=1
    ROOT_DIR="$ROOT_DIR"
    WHISPER_CPP_REPO="$fake"
    WHISPER_CPP_REF="$ref"
    SOURCE_DIR="$tmp/source"
    BUILD_DIR="$tmp/build"
    OUTPUT_DIR="$tmp/output"
    MODEL_DIR="$tmp/output/models"
    CMAKE_GENERATOR=auto
    BUILD_JOBS=2
    CMAKE_C_COMPILER_LAUNCHER=
    CMAKE_CXX_COMPILER_LAUNCHER=
    CMAKE_C_FLAGS=
    CMAKE_CXX_FLAGS=
    SCCACHE_DIR=
    GGML_NATIVE=1
    ENABLE_LTO=1
    ENABLE_CCACHE=0
    ENABLE_OPENMP=0
    ENABLE_CPU_REPACK=1
    ENABLE_FAST_MATH=0
    ENABLE_BLAS=0
    ENABLE_CUDA=0
    ENABLE_CUDA_FA=1
    CUDA_FORCE_MMQ=0
    CUDA_FORCE_CUBLAS=0
    ENABLE_HIP=0
    ENABLE_VULKAN=0
    ENABLE_SYCL=0
    ENABLE_SYCL_F16=0
    ENABLE_OPENVINO=0
    ENABLE_FFMPEG=0
    STRIP_BINARY=0
    OFFLINE=0
    SOURCE_UPDATE=0
    FORCE_SOURCE_RESET=0
    STRICT_RESOURCES=0
    FORCE_DOWNLOAD=0
    ALLOW_EXTERNAL_DIRS=1
)

run_wrapper() {
    env "${common_env[@]}" "$@"
}

run_wrapper "$ROOT_DIR/scripts/doctor.sh" >"$tmp/doctor.log" 2>&1
if grep -q -- 'CMAKE_GENERATOR was set' "$tmp/doctor.log"; then
    printf 'CMAKE_GENERATOR leaked into the CMake environment\n' >&2
    exit 1
fi
run_wrapper "$ROOT_DIR/scripts/source.sh" >/dev/null
[[ -f "$tmp/source/.native-builder-source" ]]
[[ -f "$tmp/source/.native-builder-source-dir" ]]

# Exact stamped source reuse and offline reuse must both work without fetching.
run_wrapper "$ROOT_DIR/scripts/source.sh" >/dev/null
run_wrapper OFFLINE=1 "$ROOT_DIR/scripts/source.sh" >/dev/null

# Tracked changes are protected unless the destructive reset is explicit.
printf '\n// dirty test\n' >>"$tmp/source/main.cpp"
if run_wrapper "$ROOT_DIR/scripts/source.sh" >"$tmp/dirty.log" 2>&1; then
    printf 'source protection test unexpectedly succeeded\n' >&2
    exit 1
fi
grep -q 'tracked changes' "$tmp/dirty.log"
run_wrapper FORCE_SOURCE_RESET=1 "$ROOT_DIR/scripts/source.sh" >/dev/null
if grep -q -- 'dirty test' "$tmp/source/main.cpp"; then
    printf 'FORCE_SOURCE_RESET did not remove the tracked source modification\n' >&2
    exit 1
fi

run_wrapper "$ROOT_DIR/scripts/configure.sh" >/dev/null
[[ -f "$tmp/build/.native-builder-build" ]]
run_wrapper "$ROOT_DIR/scripts/build.sh" >/dev/null
run_wrapper "$ROOT_DIR/scripts/verify.sh" >/dev/null
[[ -x "$tmp/output/bin/whisper-cli" ]]
[[ -f "$tmp/output/.native-builder-output" ]]
[[ -f "$tmp/output/metadata/build-info.txt" ]]
grep -q '^cxx_flags_release=-O3 -DNDEBUG ' "$tmp/output/metadata/build-info.txt"
grep -q '^binary_sha256=' "$tmp/output/metadata/build-info.txt"
"$tmp/output/bin/whisper-cli" --version | grep -q 'fake-test'

# Cleaning must preserve models; distclean additionally removes managed source.
mkdir -p "$tmp/output/models"
printf 'native whisper.cpp model directory\n' >"$tmp/output/models/.native-builder-models"
printf 'preserve me\n' >"$tmp/output/models/test-model.bin"
run_wrapper "$ROOT_DIR/scripts/clean.sh" build >/dev/null
[[ ! -e "$tmp/build" ]]
[[ ! -e "$tmp/output/bin/whisper-cli" ]]
[[ -d "$tmp/source/.git" ]]
[[ -f "$tmp/output/models/test-model.bin" ]]

run_wrapper "$ROOT_DIR/scripts/clean.sh" distclean >/dev/null
[[ ! -e "$tmp/source" ]]
[[ -f "$tmp/output/models/test-model.bin" ]]

run_wrapper CONFIRM=YES "$ROOT_DIR/scripts/clean.sh" purge >/dev/null
[[ ! -e "$tmp/output" ]]
