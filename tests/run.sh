#!/usr/bin/env bash
set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$TEST_DIR/.." && pwd -P)"

printf 'Running shell syntax checks...\n'
for script in "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/tests/*.sh; do
    bash -n "$script"
done

printf 'Running ShellCheck...\n'
command -v shellcheck >/dev/null 2>&1 \
    || { printf 'shellcheck is required to run the test suite\n' >&2; exit 1; }
shellcheck -P "$ROOT_DIR/scripts" -x "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/tests/*.sh

printf 'Running manifest checks...\n'
"$TEST_DIR/test-manifest.sh"

printf 'Running Makefile smoke checks...\n'
make -C "$ROOT_DIR" --no-print-directory help >/dev/null
make -C "$ROOT_DIR" --no-print-directory models >/dev/null

printf 'Running model-download validation test with a local fake transport...\n'
"$TEST_DIR/test-download.sh"

printf 'Running host-native sccache configuration test with fake tools...\n'
"$TEST_DIR/test-host-config.sh"

printf 'Running RAM/CUDA profile builds and tarball checks with fake tools...\n'
"$TEST_DIR/test-profile-builds.sh"

printf 'Running model selection and execution wrapper test with a fake binary...\n'
"$TEST_DIR/test-run-wrapper.sh"

printf 'Running end-to-end wrapper test with a local fake whisper.cpp project...\n'
"$TEST_DIR/test-build-wrapper.sh"

printf 'All tests passed.\n'
