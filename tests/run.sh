#!/usr/bin/env bash
set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$TEST_DIR/.." && pwd -P)"

printf 'Running shell syntax checks...\n'
for script in "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/tests/*.sh; do
    bash -n "$script"
done

printf 'Running manifest checks...\n'
"$TEST_DIR/test-manifest.sh"

printf 'Running Makefile smoke checks...\n'
make -C "$ROOT_DIR" --no-print-directory help >/dev/null
make -C "$ROOT_DIR" --no-print-directory models >/dev/null

printf 'Running model-download validation test with a local fake transport...\n'
"$TEST_DIR/test-download.sh"

printf 'Running end-to-end wrapper test with a local fake whisper.cpp project...\n'
"$TEST_DIR/test-build-wrapper.sh"

printf 'All tests passed.\n'
