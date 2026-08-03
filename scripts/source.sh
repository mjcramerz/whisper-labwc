#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

validate_common_config
require_cmd git

stamp="$SOURCE_DIR_ABS/.native-builder-source"
managed_marker="$SOURCE_DIR_ABS/.native-builder-source-dir"
expected_key="$WHISPER_CPP_REPO|$WHISPER_CPP_REF"

ensure_clean_checkout() {
    local changes
    changes="$(git -C "$SOURCE_DIR_ABS" status --porcelain --untracked-files=no)"
    [[ -z "$changes" ]] && return 0

    if [[ "$FORCE_SOURCE_RESET" == "1" ]]; then
        warn "Discarding tracked changes in managed source because FORCE_SOURCE_RESET=1"
        git -C "$SOURCE_DIR_ABS" reset --hard HEAD
        git -C "$SOURCE_DIR_ABS" submodule foreach --recursive 'git reset --hard HEAD' >/dev/null 2>&1 || true
    else
        printf '%s\n' "$changes" >&2
        die "Managed source has tracked changes. Set FORCE_SOURCE_RESET=1 to discard them."
    fi
}

read_stamp() {
    old_repo=''
    old_ref=''
    old_commit=''
    [[ -f "$stamp" ]] || return 1
    IFS='|' read -r old_repo old_ref old_commit <"$stamp" || return 1
    [[ -n "$old_repo" && -n "$old_ref" && -n "$old_commit" ]]
}

write_management_files() {
    local commit=$1
    printf 'native whisper.cpp source directory\nroot=%s\n' "$ROOT_DIR" >"$managed_marker"
    printf '%s|%s|%s\n' "$WHISPER_CPP_REPO" "$WHISPER_CPP_REF" "$commit" >"$stamp.tmp"
    mv -f "$stamp.tmp" "$stamp"
}

verify_source_tree() {
    [[ -f "$SOURCE_DIR_ABS/CMakeLists.txt" ]] \
        || die "The selected source ref does not contain the expected top-level CMakeLists.txt"
}

if [[ -e "$SOURCE_DIR_ABS" && ! -d "$SOURCE_DIR_ABS" ]]; then
    die "SOURCE_DIR exists but is not a directory: $SOURCE_DIR_ABS"
fi
if [[ -d "$SOURCE_DIR_ABS" && ! -d "$SOURCE_DIR_ABS/.git" ]]; then
    first_entry="$(find "$SOURCE_DIR_ABS" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    [[ -z "$first_entry" ]] || die "SOURCE_DIR exists but is not an empty directory or Git checkout: $SOURCE_DIR_ABS"
fi

if [[ -d "$SOURCE_DIR_ABS/.git" && ! -f "$managed_marker" && ! -f "$stamp" ]]; then
    if [[ "$FORCE_SOURCE_RESET" == "1" ]]; then
        warn "Adopting an existing Git checkout as managed source because FORCE_SOURCE_RESET=1"
        printf 'native whisper.cpp source directory\nroot=%s\n' "$ROOT_DIR" >"$managed_marker"
    else
        die "Refusing to modify an unmarked Git checkout in SOURCE_DIR. Use an empty path or set FORCE_SOURCE_RESET=1 to adopt it."
    fi
fi

# Reuse the exact stamped commit without touching the network. This path still
# checks for tracked modifications and restores HEAD if it was moved manually.
if [[ -d "$SOURCE_DIR_ABS/.git" && "$SOURCE_UPDATE" == "0" ]] && read_stamp; then
    if [[ "$old_repo|$old_ref" == "$expected_key" ]] \
        && git -C "$SOURCE_DIR_ABS" cat-file -e "${old_commit}^{commit}" 2>/dev/null; then
        ensure_clean_checkout
        current_commit="$(git -C "$SOURCE_DIR_ABS" rev-parse --verify HEAD)"
        if [[ "$current_commit" != "$old_commit" ]]; then
            git -C "$SOURCE_DIR_ABS" -c advice.detachedHead=false checkout --detach --force "$old_commit"
        fi
        verify_source_tree
        printf 'native whisper.cpp source directory\nroot=%s\n' "$ROOT_DIR" >"$managed_marker"
        info "Reusing whisper.cpp source at ${old_commit:0:12} ($WHISPER_CPP_REF)"
        exit 0
    fi
fi

if [[ "$OFFLINE" == "1" ]]; then
    [[ -d "$SOURCE_DIR_ABS/.git" ]] || die "OFFLINE=1 but no managed source exists at $SOURCE_DIR_ABS"
    ensure_clean_checkout

    offline_commit=''
    if read_stamp && [[ "$old_repo|$old_ref" == "$expected_key" ]] \
        && git -C "$SOURCE_DIR_ABS" cat-file -e "${old_commit}^{commit}" 2>/dev/null; then
        offline_commit="$old_commit"
    elif offline_commit="$(git -C "$SOURCE_DIR_ABS" rev-parse --verify "${WHISPER_CPP_REF}^{commit}" 2>/dev/null)"; then
        :
    else
        die "OFFLINE=1 and ref '$WHISPER_CPP_REF' is not available in the local checkout"
    fi

    git -C "$SOURCE_DIR_ABS" -c advice.detachedHead=false checkout --detach --force "$offline_commit"
    git -C "$SOURCE_DIR_ABS" submodule update --init --recursive --no-fetch \
        || die "OFFLINE=1 but one or more required submodules are unavailable locally"
    verify_source_tree
    write_management_files "$offline_commit"
    info "Offline mode: source ready at ${offline_commit:0:12} ($WHISPER_CPP_REF)"
    exit 0
fi

if [[ ! -d "$SOURCE_DIR_ABS/.git" ]]; then
    log "Initializing managed whisper.cpp source checkout"
    mkdir -p "$SOURCE_DIR_ABS"
    printf 'native whisper.cpp source directory\nroot=%s\n' "$ROOT_DIR" >"$managed_marker"
    git -C "$SOURCE_DIR_ABS" init --quiet
    git -C "$SOURCE_DIR_ABS" remote add origin "$WHISPER_CPP_REPO"
else
    ensure_clean_checkout
    printf 'native whisper.cpp source directory\nroot=%s\n' "$ROOT_DIR" >"$managed_marker"
    if git -C "$SOURCE_DIR_ABS" remote get-url origin >/dev/null 2>&1; then
        git -C "$SOURCE_DIR_ABS" remote set-url origin "$WHISPER_CPP_REPO"
    else
        git -C "$SOURCE_DIR_ABS" remote add origin "$WHISPER_CPP_REPO"
    fi
fi

log "Fetching source ref $WHISPER_CPP_REF"
git -C "$SOURCE_DIR_ABS" fetch --force --depth=1 --no-tags origin "$WHISPER_CPP_REF"
commit="$(git -C "$SOURCE_DIR_ABS" rev-parse --verify FETCH_HEAD)"
git -C "$SOURCE_DIR_ABS" -c advice.detachedHead=false checkout --detach --force "$commit"
git -C "$SOURCE_DIR_ABS" submodule sync --recursive
git -C "$SOURCE_DIR_ABS" submodule update --init --recursive --depth=1
verify_source_tree
write_management_files "$commit"
info "Source ready: ${commit:0:12} ($WHISPER_CPP_REF)"
