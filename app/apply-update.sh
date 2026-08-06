#!/bin/sh
# Move a staged update into place. Run by launch.sh, never by hand.
#
#     apply-update.sh <app-dir> <stage-dir>
#
# This is the only code that writes to the app directory, and it runs at the one
# moment when nothing inside that directory is executing: launch.sh `exec`s it,
# so launch.sh is no longer being read from disk, and chat.sh has not started.
# It is itself run from a copy inside the stage directory, which the copy below
# never touches.
#
# The last thing it does is exec launch.sh from the tree it just installed, so
# an update finishes on the launch that started it rather than needing another.

set -eu

APP_DIR="${1:-}"
STAGE_DIR="${2:-}"

if [ -z "$APP_DIR" ] || [ -z "$STAGE_DIR" ]; then
    printf 'apply-update: usage: apply-update.sh <app-dir> <stage-dir>\n' >&2
    exit 1
fi

TREE="$STAGE_DIR/tree/App/DPadChat"
LOG="$STAGE_DIR/apply.log"

say() {
    printf '%s apply-update: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || :
}

# Whatever happens below, the device must end up running the app. Handing back
# to launch.sh is the fallback for every failure, because a handheld with no
# keyboard and no shell has no other way out of a launcher that gave up.
hand_off() {
    say "handing off to $APP_DIR/launch.sh"
    if [ -x "$APP_DIR/launch.sh" ]; then
        exec "$APP_DIR/launch.sh"
    fi
    exec /bin/sh "$APP_DIR/launch.sh"
}

# The marker is consumed before anything is copied, and deliberately so. If this
# script fails halfway, the next launch runs the old launcher instead of
# retrying a copy that already failed once: a broken install that starts is
# recoverable over SSH, and a launcher stuck in a retry loop is not.
say "starting; app=$APP_DIR stage=$STAGE_DIR"
rm -f "$STAGE_DIR/ready" 2>/dev/null || :

if [ ! -d "$TREE" ]; then
    say 'no staged tree; nothing to apply'
    hand_off
fi

# Re-checked here rather than trusted from staging time: the card may have been
# pulled, or the write may never have reached it.
for required in config.json launch.sh chat.sh lib/common.sh res/cacert.pem; do
    if [ ! -f "$TREE/$required" ]; then
        say "staged tree is incomplete ($required missing); not applying"
        hand_off
    fi
done

# Copied file by file rather than as a whole directory, so the data directory
# living inside the app directory is left alone. Files dropped by a new release
# are left behind rather than deleted; a stale library nothing sources is
# harmless, and a delete pass is the step that could remove the wrong thing.
copied=0
failed=0

# `find` rather than a glob: the tree is two levels deep and `*` would not
# reach lib/ or res/. One process, and no `cd` into a directory this script
# goes on to delete.
find "$TREE" -type f -print >"$STAGE_DIR/files.txt" 2>/dev/null || :

while IFS= read -r file; do
    relative="${file#"$TREE"/}"
    [ -n "$relative" ] || continue

    target="$APP_DIR/$relative"
    parent="${target%/*}"

    if ! mkdir -p "$parent" 2>/dev/null; then
        say "could not create $parent"
        failed=$((failed + 1))
        continue
    fi

    if cp "$TREE/$relative" "$target" 2>/dev/null; then
        copied=$((copied + 1))
    else
        say "could not write $relative"
        failed=$((failed + 1))
    fi
done <"$STAGE_DIR/files.txt"

# Set explicitly rather than inherited: the archive is often built on, and
# unpacked onto, filesystems that do not record an executable bit.
for executable in launch.sh chat.sh apply-update.sh; do
    [ -f "$APP_DIR/$executable" ] || continue
    chmod 755 "$APP_DIR/$executable" 2>/dev/null || :
done

say "copied $copied file(s), $failed failure(s)"

# Keep the tree when something went wrong: it is the only evidence of what was
# attempted, and a second launch can retry the copy from it.
if [ "$failed" -eq 0 ]; then
    rm -rf "$STAGE_DIR/tree" 2>/dev/null || :
    rm -f "$STAGE_DIR/files.txt" "$STAGE_DIR/entries.txt" \
        "$STAGE_DIR/unpack.err" 2>/dev/null || :
    say 'update applied'
fi

hand_off
