#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''
while (($#)); do
    case "$1" in
        --output)
            output=$2
            shift 2
            ;;
        --output=*)
            output=${1#--output=}
            shift
            ;;
        *)
            shift
            ;;
    esac
done
[[ -n "$output" ]]
[[ -z "${HF_TOKEN:-}" ]] || { printf 'HF_TOKEN leaked to transport environment\n' >&2; exit 90; }
printf 'call\n' >>"${FAKE_CURL_COUNT:?}"
[[ "${FAKE_CURL_FAIL:-0}" == "0" ]] || exit 22
truncate -s $((31 * 1024 * 1024)) "$output"
printf '\x6c\x6d\x67\x67' | dd of="$output" bs=1 seek=0 conv=notrunc status=none
SH
chmod 0755 "$tmp/bin/curl"

common_env=(
    CONFIG_FROM_MAKE=1
    ROOT_DIR="$ROOT_DIR"
    SOURCE_DIR="$tmp/source"
    BUILD_DIR="$tmp/build"
    OUTPUT_DIR="$tmp/output"
    MODEL_DIR="$tmp/models"
    MODEL=tiny-q5_1
    ENABLE_CUDA=0
    ENABLE_HIP=0
    ENABLE_VULKAN=0
    ENABLE_SYCL=0
    ENABLE_SYCL_F16=0
    FORCE_DOWNLOAD=0
    OFFLINE=0
    STRICT_RESOURCES=0
    ALLOW_EXTERNAL_DIRS=1
    PATH="$tmp/bin:$PATH"
    FAKE_CURL_COUNT="$tmp/curl-count"
)

run_download() {
    env "${common_env[@]}" "$ROOT_DIR/scripts/download-model.sh" >/dev/null
}

run_download
model="$tmp/models/ggml-tiny-q5_1.bin"
[[ -f "$model" ]]
[[ -f "$model.meta" ]]
[[ -f "$tmp/models/.native-builder-models" ]]
grep -q '^model=tiny-q5_1$' "$model.meta"
grep -Eq '^local_sha256=[0-9a-f]{64}$' "$model.meta"
[[ "$(wc -l <"$tmp/curl-count")" -eq 1 ]]

# A valid existing model is reused without contacting the downloader.
run_download
[[ "$(wc -l <"$tmp/curl-count")" -eq 1 ]]

# Invalid completed payloads are preserved for diagnosis, then replaced.
printf '<html>bad payload</html>' | dd of="$model" bs=1 seek=0 conv=notrunc status=none
run_download
[[ "$(wc -l <"$tmp/curl-count")" -eq 2 ]]
compgen -G "$model.corrupt.*" >/dev/null
magic="$(od -An -N4 -tx1 "$model" | tr -d '[:space:]')"
[[ "$magic" == 6c6d6767 ]]

# Invalid credentials are rejected before filesystem changes or transport use.
model_sha_before="$(sha256sum "$model" | awk '{print $1}')"
calls_before="$(wc -l <"$tmp/curl-count")"
if env "${common_env[@]}" FORCE_DOWNLOAD=1 HF_TOKEN='bad\token' \
    "$ROOT_DIR/scripts/download-model.sh" >"$tmp/token.log" 2>&1; then
    printf 'invalid HF_TOKEN test unexpectedly succeeded\n' >&2
    exit 1
fi
grep -q 'HF_TOKEN contains unsupported' "$tmp/token.log"
[[ -f "$model" ]]
[[ "$(sha256sum "$model" | awk '{print $1}')" == "$model_sha_before" ]]
[[ "$(wc -l <"$tmp/curl-count")" -eq "$calls_before" ]]


# Credential-bearing transport configuration is removed even when transport fails.
auth_tmp="$tmp/auth-tmp"
mkdir -p "$auth_tmp"
if env "${common_env[@]}" FORCE_DOWNLOAD=1 HF_TOKEN='hf_test_token' FAKE_CURL_FAIL=1 TMPDIR="$auth_tmp" \
    "$ROOT_DIR/scripts/download-model.sh" >"$tmp/auth-failure.log" 2>&1; then
    printf 'forced transport failure unexpectedly succeeded\n' >&2
    exit 1
fi
grep -q 'Download failed' "$tmp/auth-failure.log"
[[ -z "$(find "$auth_tmp" -mindepth 1 -print -quit)" ]]
[[ -f "$model" ]]
[[ "$(sha256sum "$model" | awk '{print $1}')" == "$model_sha_before" ]]
