#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

fake_upstream="$tmp/fake-upstream"
fake_bin="$tmp/bin"
mkdir -p -- "$fake_upstream" "$fake_bin"
cat >"$fake_upstream/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.18)
project(fake_whisper_profiles LANGUAGES C CXX)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
add_executable(whisper-cli main.cpp)
add_executable(whisper-server main.cpp)
CMAKE
cat >"$fake_upstream/main.cpp" <<'CPP'
#include <iostream>
#include <string>
int main(int argc, char ** argv) {
    if (argc > 1 && std::string(argv[1]) == "--version") {
        std::cout << "whisper.cpp fake-profile 1.0\n";
        return 0;
    }
    std::cout << "fake whisper executable\n";
    return 0;
}
CPP
printf 'MIT test license\n' >"$fake_upstream/LICENSE"
git -C "$fake_upstream" init -q
git -C "$fake_upstream" config user.email test@example.invalid
git -C "$fake_upstream" config user.name test
git -C "$fake_upstream" add .
git -C "$fake_upstream" commit -q -m initial
ref="$(git -C "$fake_upstream" rev-parse HEAD)"

cat >"$fake_bin/nvcc" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
for argument in "$@"; do
    if [[ "$argument" == "--version" ]]; then
        printf 'Cuda compilation tools, release 12.8, V12.8.0\n'
        exit 0
    fi
done
output=''
while (($#)); do
    case "$1" in
        -o)
            output=$2
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
[[ -n "$output" ]] || exit 2
: >"$output"
SH
chmod 0755 "$fake_bin/nvcc"

common_make_args=(
    --no-print-directory
    "WHISPER_CPP_REPO=$fake_upstream"
    "WHISPER_CPP_REF=$ref"
    ALLOW_EXTERNAL_DIRS=1
    OFFLINE=0
    SOURCE_UPDATE=0
    FORCE_SOURCE_RESET=0
)

ram_archive="$tmp/artifacts/whisper-ram.tar.gz"
PATH="$fake_bin:$PATH" make -C "$ROOT_DIR" "${common_make_args[@]}" build-ram \
    "WHISPER_RAM_SOURCE_DIR=$tmp/source" \
    "WHISPER_RAM_BUILD_DIR=$tmp/build/ram" \
    "WHISPER_RAM_OUTPUT_DIR=$tmp/output/ram" \
    "WHISPER_RAM_MODEL_DIR=$tmp/models" \
    "WHISPER_RAM_ARCHIVE_PATH=$ram_archive" \
    WHISPER_RAM_SCCACHE_DIR= \
    WHISPER_RAM_SCCACHE_SERVER_UDS= \
    WHISPER_RAM_CMAKE_C_COMPILER_LAUNCHER= \
    WHISPER_RAM_CMAKE_CXX_COMPILER_LAUNCHER= \
    WHISPER_RAM_CMAKE_CUDA_COMPILER_LAUNCHER= \
    WHISPER_RAM_CMAKE_CUDA_HOST_COMPILER= \
    WHISPER_RAM_CMAKE_C_FLAGS= \
    WHISPER_RAM_CMAKE_CXX_FLAGS= \
    WHISPER_RAM_GGML_NATIVE=0 \
    WHISPER_RAM_ENABLE_LTO=0 \
    WHISPER_RAM_ENABLE_OPENMP=0 \
    WHISPER_RAM_STRIP_BINARY=0 >"$tmp/build-ram.log" 2>&1

[[ -x "$tmp/output/ram/bin/whisper-cli" ]]
[[ -x "$tmp/output/ram/bin/whisper-server" ]]
[[ -f "$ram_archive" ]]
grep -Fqx 'build_profile=ram' "$tmp/output/ram/metadata/build-info.txt"
grep -Fqx 'backend=CPU' "$tmp/output/ram/metadata/build-info.txt"
ram_archive_listing="$tmp/ram-archive-listing.txt"
tar -tzf "$ram_archive" >"$ram_archive_listing"
grep -Fqx 'whisper-ram/bin/whisper-cli' "$ram_archive_listing"
grep -Fqx 'whisper-ram/bin/whisper-server' "$ram_archive_listing"

cuda_archive="$tmp/artifacts/whisper-cuda.tar.gz"
PATH="$fake_bin:$PATH" make -C "$ROOT_DIR" "${common_make_args[@]}" build-cuda \
    "WHISPER_CUDA_SOURCE_DIR=$tmp/source" \
    "WHISPER_CUDA_BUILD_DIR=$tmp/build/cuda" \
    "WHISPER_CUDA_OUTPUT_DIR=$tmp/output/cuda" \
    "WHISPER_CUDA_MODEL_DIR=$tmp/models" \
    "WHISPER_CUDA_ARCHIVE_PATH=$cuda_archive" \
    WHISPER_CUDA_SCCACHE_DIR= \
    WHISPER_CUDA_SCCACHE_SERVER_UDS= \
    WHISPER_CUDA_CMAKE_C_COMPILER_LAUNCHER= \
    WHISPER_CUDA_CMAKE_CXX_COMPILER_LAUNCHER= \
    WHISPER_CUDA_CMAKE_CUDA_COMPILER_LAUNCHER= \
    "WHISPER_CUDA_CMAKE_CUDA_COMPILER=$fake_bin/nvcc" \
    WHISPER_CUDA_CMAKE_CUDA_HOST_COMPILER= \
    WHISPER_CUDA_CMAKE_C_COMPILER= \
    WHISPER_CUDA_CMAKE_CXX_COMPILER= \
    WHISPER_CUDA_ENABLE_CUDA_GLIBC_COMPAT=0 \
    WHISPER_CUDA_CUDA_GLIBC_HEADER= \
    WHISPER_CUDA_CUDA_GLIBC_COMPAT_DIR= \
    WHISPER_CUDA_CMAKE_C_FLAGS= \
    WHISPER_CUDA_CMAKE_CXX_FLAGS= \
    WHISPER_CUDA_GGML_NATIVE=0 \
    WHISPER_CUDA_ENABLE_LTO=0 \
    WHISPER_CUDA_ENABLE_OPENMP=0 \
    WHISPER_CUDA_STRIP_BINARY=0 >"$tmp/build-cuda.log" 2>&1

[[ -x "$tmp/output/cuda/bin/whisper-cli" ]]
[[ -x "$tmp/output/cuda/bin/whisper-server" ]]
[[ -f "$cuda_archive" ]]
grep -Fqx 'build_profile=cuda' "$tmp/output/cuda/metadata/build-info.txt"
grep -Fqx 'backend=CUDA' "$tmp/output/cuda/metadata/build-info.txt"
grep -Fqx 'cuda_architectures=61' "$tmp/output/cuda/metadata/build-info.txt"
grep -F -- '-DWHISPER_BUILD_SERVER=ON' "$tmp/output/cuda/metadata/cmake-command.txt" >/dev/null
grep -F -- '-DGGML_CUDA=ON' "$tmp/output/cuda/metadata/cmake-command.txt" >/dev/null
grep -F -- '-DCMAKE_CUDA_ARCHITECTURES=61' "$tmp/output/cuda/metadata/cmake-command.txt" >/dev/null
grep -F -- '-DGGML_CUDA_NO_PEER_COPY=ON' "$tmp/output/cuda/metadata/cmake-command.txt" >/dev/null
grep -F -- '-DGGML_CUDA_NCCL=OFF' "$tmp/output/cuda/metadata/cmake-command.txt" >/dev/null
cuda_archive_listing="$tmp/cuda-archive-listing.txt"
tar -tzf "$cuda_archive" >"$cuda_archive_listing"
grep -Fqx 'whisper-cuda/bin/whisper-cli' "$cuda_archive_listing"
grep -Fqx 'whisper-cuda/bin/whisper-server' "$cuda_archive_listing"

if make -C "$ROOT_DIR" --no-print-directory info-ram ENABLE_CUDA=1 \
    WHISPER_RAM_CMAKE_C_COMPILER_LAUNCHER= \
    WHISPER_RAM_CMAKE_CXX_COMPILER_LAUNCHER= \
    WHISPER_RAM_SCCACHE_DIR= \
    WHISPER_RAM_SCCACHE_SERVER_UDS= >"$tmp/invalid-ram.log" 2>&1; then
    printf 'RAM profile unexpectedly accepted ENABLE_CUDA=1\n' >&2
    exit 1
fi
grep -Fq 'ram profile must not enable a primary GPU backend' "$tmp/invalid-ram.log"
