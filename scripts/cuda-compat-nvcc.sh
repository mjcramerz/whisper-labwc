#!/usr/bin/env bash
set -Eeuo pipefail

die() { printf 'cuda-compat-nvcc: %s\n' "$*" >&2; exit 1; }

real_compiler=${CMAKE_CUDA_COMPILER:-}
system_header=${CUDA_GLIBC_HEADER_ABS:-}
compat_dir=${CUDA_GLIBC_COMPAT_DIR_ABS:-}
patched_header=${CUDA_GLIBC_PATCHED_HEADER_ABS:-}

[[ "$real_compiler" = /* && -x "$real_compiler" ]] \
    || die "CMAKE_CUDA_COMPILER must be an executable absolute path"
[[ "$system_header" = /* && -f "$system_header" ]] \
    || die "CUDA_GLIBC_HEADER_ABS must identify the installed CUDA header"
[[ "$compat_dir" = /* && -d "$compat_dir" ]] \
    || die "CUDA_GLIBC_COMPAT_DIR_ABS must identify the prepared compatibility directory"
[[ "$patched_header" = "$compat_dir/"* && -f "$patched_header" ]] \
    || die "CUDA_GLIBC_PATCHED_HEADER_ABS must identify the prepared patched header"
command -v bwrap >/dev/null 2>&1 || die "bubblewrap is required"

bwrap_args=(
    --die-with-parent
    --ro-bind / /
    --dev-bind /dev /dev
    --proc /proc
)

add_writable_bind() {
    local path=${1:-}
    [[ -n "$path" && "$path" = /* && -d "$path" ]] || return 0
    case "$path" in
        /|/usr|/etc|/bin|/sbin|/lib|/lib64) die "refusing unsafe writable bind: $path" ;;
    esac
    bwrap_args+=(--bind "$path" "$path")
}

add_writable_bind /tmp
add_writable_bind "${BUILD_DIR_ABS:-}"
add_writable_bind "${SCCACHE_DIR_ABS:-}"
add_writable_bind "${XDG_RUNTIME_DIR:-}"
bwrap_args+=(--ro-bind "$patched_header" "$system_header" --chdir "$PWD")

exec bwrap "${bwrap_args[@]}" "$real_compiler" "$@"
