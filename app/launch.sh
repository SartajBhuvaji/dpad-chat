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

cd "$SYSDIR"

# st consumes every argument after -e as the command to run, so it must be last.
exec ./bin/st -e "$APP_DIR/chat.sh"
