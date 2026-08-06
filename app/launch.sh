#!/bin/sh
# Onion OS entry point. Referenced by the "launch" field of config.json.
#
# Starts Onion's bundled `st` terminal with chat.sh as the child process, so
# the app inherits st's on-screen keyboard (X toggles it) with no extra work.

set -eu

APP_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
SYSDIR='/mnt/SDCARD/.tmp_update'

PATH="$SYSDIR/bin:$PATH"
LD_LIBRARY_PATH="$SYSDIR/lib:${LD_LIBRARY_PATH:-}"
export PATH LD_LIBRARY_PATH

# st resolves its terminfo and font relative to HOME on this platform.
HOME='/mnt/SDCARD'
export HOME

if [ ! -x "$SYSDIR/bin/st" ]; then
    printf 'dpad-chat: %s not found. Onion OS 4.x is required.\n' "$SYSDIR/bin/st" >&2
    exit 1
fi

# An update staged by /update is applied here, before anything from the app
# directory is running. `exec` matters: it replaces this process, so this file
# is no longer being read from disk while the installer overwrites it. The
# installer hands back by exec'ing this script again, with the marker gone.
DATA_DIR="${DPAD_DATA_DIR:-$APP_DIR/data}"
STAGE_DIR="$DATA_DIR/update"

if [ -f "$STAGE_DIR/ready" ] && [ -x "$STAGE_DIR/apply.sh" ]; then
    exec "$STAGE_DIR/apply.sh" "$APP_DIR" "$STAGE_DIR"
fi

cd "$SYSDIR"

# st consumes every argument after -e as the command to run, so it must be last.
exec ./bin/st -e "$APP_DIR/chat.sh"
