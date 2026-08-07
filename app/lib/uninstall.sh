#!/bin/sh
# Staging for /uninstall.
#
# The same split as the self-update, for the same reason. This file runs inside
# the app and only ever copies; uninstall.sh does the deleting, from a copy
# outside the app directory. Nothing here removes anything, so a failure at any
# point leaves the install exactly as it was.

# UNINSTALL_* are this module's interface, read by chat.sh after sourcing.
# Static analysis works one file at a time and cannot see those uses.
# shellcheck disable=SC2034

UNINSTALL_ERROR=''
UNINSTALL_SCRIPT=''
UNINSTALL_WORK=''
UNINSTALL_APP_DIR=''

# uninstall_init <app-dir>
uninstall_init() {
    UNINSTALL_APP_DIR="$1"
}

# Copy the remover somewhere the remover is not about to delete, and report the
# path in UNINSTALL_SCRIPT. Returns non-zero with a message in UNINSTALL_ERROR,
# which is the whole reason this is separate from the exec below: everything
# that can fail happens while the app is still there to say so.
uninstall_stage() {
    UNINSTALL_ERROR=''
    UNINSTALL_SCRIPT=''

    source_script="$UNINSTALL_APP_DIR/uninstall.sh"

    if [ ! -f "$source_script" ]; then
        UNINSTALL_ERROR='uninstall.sh is missing from the app folder.'
        return 1
    fi

    # TMPDIR on the device is a tmpfs, not the card, which is what keeps the
    # copy out of reach of the delete. mktemp is already required at startup.
    UNINSTALL_WORK=$(mktemp -d 2>/dev/null || mktemp -d -t dpad) || UNINSTALL_WORK=''

    if [ -z "$UNINSTALL_WORK" ] || [ ! -d "$UNINSTALL_WORK" ]; then
        UNINSTALL_ERROR='Could not create a working directory.'
        return 1
    fi

    # A relative work directory would be resolved against a directory that is
    # about to be deleted, and one inside the app would be deleted along with
    # it, mid-run. Neither can be allowed to reach the exec.
    case "$UNINSTALL_WORK" in
        /*) ;;
        *)
            UNINSTALL_ERROR='The working directory is not an absolute path.'
            return 1
            ;;
    esac

    case "$UNINSTALL_WORK/" in
        "$UNINSTALL_APP_DIR"/*)
            UNINSTALL_ERROR='The working directory is inside the app folder.'
            return 1
            ;;
    esac

    if ! cp "$source_script" "$UNINSTALL_WORK/uninstall.sh" 2>/dev/null; then
        UNINSTALL_ERROR='Could not prepare the uninstaller.'
        return 1
    fi

    chmod 755 "$UNINSTALL_WORK/uninstall.sh" 2>/dev/null || :

    UNINSTALL_SCRIPT="$UNINSTALL_WORK/uninstall.sh"
    return 0
}

# Replace this process with the remover. It never returns, and it must not: an
# `exec` is what guarantees no part of the app is still executing from the
# directory being deleted.
#
# Invoked through /bin/sh rather than by its own shebang. The staged copy is
# executable, but the card is FAT32 and the mode bit on the original is not
# something to stake the last step on.
uninstall_exec() {
    exec /bin/sh "$UNINSTALL_SCRIPT" "$UNINSTALL_APP_DIR" "$UNINSTALL_WORK"
}
