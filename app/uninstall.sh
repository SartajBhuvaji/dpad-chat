#!/bin/sh
# Delete the app from the card. Run by chat.sh, never by hand.
#
#     uninstall.sh <app-dir>
#
# This is apply-update.sh's hazard in reverse. The shell reads a script
# incrementally from an open descriptor, so a script that deletes the directory
# it is being read from resumes at a byte offset in files that are no longer
# there. chat.sh copies this file to a work directory outside the app and execs
# it from there, so by the time anything is removed nothing under the app
# directory is executing.
#
# Everything below the first check is written to be safe to run twice: the
# device has no shell of its own to recover with, so a half-finished uninstall
# has to be fixable by running the same thing again.

set -eu

# Wrapped in a function so the interpreter has parsed the whole file before the
# first delete. Nothing is read from disk after main starts, which is what makes
# it safe for this script to remove the tree it was copied from.
main() {
    app_dir="${1:-}"
    work_dir="${2:-}"

    if [ -z "$app_dir" ]; then
        say 'usage: uninstall.sh <app-dir>'
        return 1
    fi

    # Resolved rather than trusted. A relative path here would be resolved
    # against whatever directory this process happens to be in, and the whole
    # of the next check depends on knowing exactly what is about to be deleted.
    resolved=$(CDPATH='' cd -- "$app_dir" 2>/dev/null && pwd -P) || resolved=''

    if [ -z "$resolved" ]; then
        say "nothing to remove: $app_dir is not there"
        return 0
    fi

    if ! is_an_install "$resolved"; then
        say "refusing to delete $resolved"
        say 'it does not look like a D-Pad Chat install'
        return 1
    fi

    # cd out of the tree before removing it. Deleting the working directory out
    # from under a running process leaves it with no valid cwd, and busybox
    # reports the confusing failures that follow against the wrong path.
    cd /

    if ! rm -rf "$resolved" 2>/dev/null; then
        say "could not remove $resolved"
        say 'the card may be write-protected or mounted read-only.'
        return 1
    fi

    if [ -d "$resolved" ]; then
        say "part of $resolved is still there"
        say 'delete the folder from a computer to finish.'
        return 1
    fi

    printf '\n'
    say 'D-Pad Chat has been removed.'
    printf '\n'
    say 'Your API key went with it. Revoke it at'
    say 'platform.openai.com/api-keys if the card or'
    say 'the device is going to someone else.'
    printf '\n'

    # The work directory is the copy this script is running from. Removing it
    # is safe here: the file is already parsed, and an unlinked inode stays
    # readable while a descriptor is open on it.
    if [ -n "$work_dir" ]; then
        case "$work_dir" in
            /*/*) rm -rf "$work_dir" 2>/dev/null || : ;;
        esac
    fi

    return 0
}

say() {
    printf '%s\n' "$*"
}

# The guard on `rm -rf`, and the reason this takes a path rather than assuming
# one. A missing argument, a truncated variable or a stale path would otherwise
# reach the delete, and on this device that could be the card root.
#
# The marker files are the app's own: a directory holding all four is a D-Pad
# Chat install and nothing else. The depth check is a second floor under that,
# because /mnt/SDCARD and /mnt/SDCARD/App are one bad substitution away from
# each other and neither could ever hold these files anyway.
is_an_install() {
    case "$1" in
        /*/*/*) ;;
        *) return 1 ;;
    esac

    for marker in config.json launch.sh chat.sh lib/common.sh; do
        [ -f "$1/$marker" ] || return 1
    done

    return 0
}

# Hold the screen. st closes the moment this process exits, taking the report
# with it, and the user has no other way to see whether the delete worked.
# Select quits st from here exactly as it does from the app.
wait_for_exit() {
    [ -t 0 ] || return 0
    printf 'Press Select to exit.\n'
    IFS= read -r _ignored || :
}

if main "$@"; then
    wait_for_exit
    exit 0
fi

wait_for_exit
exit 1
