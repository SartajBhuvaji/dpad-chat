#!/bin/sh
# Shared runtime helpers for D-Pad Chat.
#
# POSIX sh only: the Miyoo Mini+ runs busybox ash. No arrays, no [[ ]],
# no $'...', no local -a. Verified with `dash -n` and shellcheck -s sh.

# Consumed by the scripts that source this file.
# shellcheck disable=SC2034
DPADCHAT_VERSION='0.2.0'

# Root of Onion's bundled binaries and shared libraries.
ONION_SYSDIR='/mnt/SDCARD/.tmp_update'

# Maximum log size before rotation, in bytes. SD cards are small and slow;
# one rotation is enough to debug a failed session without unbounded growth.
LOG_MAX_BYTES=262144

# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------

# True when running on an actual Onion OS device rather than a dev machine.
# tools/simulate.sh and the Docker harness leave ONION_SYSDIR absent, so the
# same scripts take the simulated path without needing an explicit flag.
is_device() {
    [ -d "$ONION_SYSDIR" ]
}

# Absolute, symlink-resolved directory containing the given script.
script_dir() {
    CDPATH='' cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P
}

# Populate PATH and LD_LIBRARY_PATH with Onion's bundled curl, jq and ntpdate.
# On a dev machine the system copies are used instead.
setup_paths() {
    if is_device; then
        PATH="$ONION_SYSDIR/bin:$PATH"
        LD_LIBRARY_PATH="$ONION_SYSDIR/lib:${LD_LIBRARY_PATH:-}"
        export PATH LD_LIBRARY_PATH
    fi
}

# Fail early with an actionable message rather than midway through a request.
require_cmd() {
    missing=''
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        die "Missing required command(s):$missing"
    fi
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

# Must be called once, with the data directory, before any log_* call. The
# directory is created here because it is git-ignored and so is absent on a
# fresh checkout or install.
log_init() {
    [ $# -eq 1 ] || return 1
    mkdir -p "$1" || return 1
    LOG_FILE="$1/dpad-chat.log"
    _rotate_log
    log_info "--- D-Pad Chat $DPADCHAT_VERSION starting ---"
}

_rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    size=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || :
    fi
}

_log() {
    level="$1"
    shift
    # No-op until log_init has run, so sourcing this file is side-effect free.
    [ -n "${LOG_FILE:-}" ] || return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        >>"$LOG_FILE" 2>/dev/null || :
}

log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }

# Log to file and abort. Callers that need the message on screen should render
# it with ui_error first; die() writes to stderr so it survives a broken UI.
die() {
    log_error "$*"
    printf 'dpad-chat: %s\n' "$*" >&2
    exit 1
}
