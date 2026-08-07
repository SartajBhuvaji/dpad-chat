#!/bin/sh
# Uninstall tests.
#
# The remover is run for real, against throwaway directories. Nothing here is
# asserted from reading the source: this is the one script in the project whose
# mistake is an `rm -rf` on the wrong path, and the only useful evidence that it
# deletes what it should — and refuses everything else — is a directory that is
# gone and a sibling that is not.
#
# The command is then driven end to end through the REPL, with DPAD_SYSDIR
# standing in for Onion's system directory so chat.sh takes its on-device path.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
UNINSTALLER="$REPO_ROOT/app/uninstall.sh"

TESTS_RUN=0
TESTS_FAILED=0

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

# Present for is_device to find. Empty is enough; nothing here execs Onion's
# binaries, and the app only tests for the directory.
FAKE_SYSDIR="$WORK_DIR/sysdir"
mkdir -p "$FAKE_SYSDIR"

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  ok    %s\n' "$1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL  %s\n' "$1"
    [ -z "${2:-}" ] || printf '        %s\n' "$2"
}

assert_says() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "expected to find '$3' in: $2" ;;
    esac
}

assert_gone() {
    if [ -e "$2" ]; then
        fail "$1" "$2 is still there"
    else
        pass "$1"
    fi
}

assert_there() {
    if [ -e "$2" ]; then
        pass "$1"
    else
        fail "$1" "$2 was removed"
    fi
}

assert_status() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected exit $3, got $2"
    fi
}

# A directory holding the four files the remover looks for, plus the runtime
# state a real install would have, inside a parent that must survive.
build_install() {
    root="$WORK_DIR/card"
    rm -rf "$root"
    mkdir -p "$root/App/DPadChat/lib" "$root/App/DPadChat/res" \
        "$root/App/DPadChat/data" "$root/App/OtherApp"

    for file in config.json launch.sh chat.sh; do
        printf 'placeholder\n' >"$root/App/DPadChat/$file"
    done
    printf 'placeholder\n' >"$root/App/DPadChat/lib/common.sh"
    printf 'api_key=secret\n' >"$root/App/DPadChat/data/settings.cfg"
    printf 'the conversation\n' >"$root/App/DPadChat/data/history.json"
    printf 'another app\n' >"$root/App/OtherApp/config.json"

    printf '%s' "$root/App/DPadChat"
}

# Run the remover the way chat.sh does, from a copy outside the target.
remove() {
    copy_dir="$WORK_DIR/run"
    rm -rf "$copy_dir"
    mkdir -p "$copy_dir"
    cp "$UNINSTALLER" "$copy_dir/uninstall.sh"

    set +e
    REMOVE_OUT=$(/bin/sh "$copy_dir/uninstall.sh" "$@" 2>&1)
    REMOVE_STATUS=$?
    set -e
}

# Drive the REPL with the given input against a copy of the app, and report
# where that copy is in APP_COPY.
run_app() {
    APP_COPY="$WORK_DIR/card/App/DPadChat"
    rm -rf "$WORK_DIR/card"
    mkdir -p "$WORK_DIR/card/App"
    cp -R "$REPO_ROOT/app" "$APP_COPY"
    rm -rf "$APP_COPY/data"

    # DPAD_DATA_DIR is pinned to where the app would put it anyway, rather than
    # left to the environment: the Docker harness sets it to a path outside the
    # tree, and the layout being deleted here is the device's.
    set +e
    APP_OUT=$(printf '%s' "$1" | env COLUMNS=40 NO_COLOR=1 \
        DPAD_DATA_DIR="$APP_COPY/data" \
        DPAD_SYSDIR="${2:-$FAKE_SYSDIR}" "$APP_COPY/chat.sh" 2>&1)
    set -e
}

# -----------------------------------------------------------------------------

printf 'Running uninstall tests\n'

NO_COLOR=1
export NO_COLOR

# -----------------------------------------------------------------------------
# The remover
# -----------------------------------------------------------------------------

printf '\nThe remover\n'

app=$(build_install)
remove "$app"

assert_status 'a real install is removed' "$REMOVE_STATUS" 0
assert_gone 'the app directory is gone' "$app"
assert_says 'it says what it did' "$REMOVE_OUT" 'has been removed'
assert_says 'it says the key went with it' "$REMOVE_OUT" 'Revoke it'
assert_there 'the app beside it is untouched' "$WORK_DIR/card/App/OtherApp/config.json"
assert_there 'the folder above it is untouched' "$WORK_DIR/card/App"

# The whole install, not the parts of it the app happens to know about.
app=$(build_install)
remove "$app"
assert_gone 'the settings go with it' "$WORK_DIR/card/App/DPadChat/data/settings.cfg"

# The copy the remover is running from. Left behind it would sit in the
# device's tmpfs until the next reboot.
app=$(build_install)
scratch="$WORK_DIR/scratch"
mkdir -p "$scratch"
remove "$app" "$scratch"
assert_gone 'the work directory cleans itself up' "$scratch"

# -----------------------------------------------------------------------------
# What it refuses
# -----------------------------------------------------------------------------

printf '\nWhat it refuses\n'

# The guard that matters. Every one of these is a path that could arrive from a
# truncated variable or a mistyped call, and none of them may be deleted.
build_install >/dev/null
notanapp="$WORK_DIR/card/App/OtherApp"
remove "$notanapp"
assert_status 'a directory that is not an install is refused' "$REMOVE_STATUS" 1
assert_there 'and is still there' "$notanapp/config.json"
assert_says 'and says why' "$REMOVE_OUT" 'does not look like'

# An install missing one of its own files is not an install either: this is the
# shape a half-applied update leaves, and it is not what this deletes.
build_install >/dev/null
rm -f "$WORK_DIR/card/App/DPadChat/lib/common.sh"
remove "$WORK_DIR/card/App/DPadChat"
assert_status 'an incomplete tree is refused' "$REMOVE_STATUS" 1
assert_there 'and is left alone' "$WORK_DIR/card/App/DPadChat/chat.sh"

remove '/'
assert_status 'the root directory is refused' "$REMOVE_STATUS" 1
assert_says 'the root directory says why' "$REMOVE_OUT" 'does not look like'

remove '/mnt'
assert_status 'a shallow path is refused' "$REMOVE_STATUS" 1

remove
assert_status 'no argument is refused' "$REMOVE_STATUS" 1
assert_says 'no argument prints the usage' "$REMOVE_OUT" 'usage:'

# Already gone is the second run of a delete that half worked, and has to be
# reported as finished rather than as a failure.
remove "$WORK_DIR/not-there"
assert_status 'a path that is not there is not an error' "$REMOVE_STATUS" 0
assert_says 'and says so' "$REMOVE_OUT" 'nothing to remove'

# -----------------------------------------------------------------------------
# The command
# -----------------------------------------------------------------------------

printf '\nThe command\n'

run_app '/uninstall
y
y
'
assert_says 'the command warns what goes' "$APP_OUT" 'Your API key'
assert_says 'the command asks twice' "$APP_OUT" 'Last chance'
assert_says 'the command reports the delete' "$APP_OUT" 'has been removed'
assert_gone 'the app removes itself' "$APP_COPY"

run_app '/uninstall
n
/quit
'
assert_says 'no at the first prompt leaves it alone' "$APP_OUT" 'Left as it is'
assert_there 'and the app is still there' "$APP_COPY/chat.sh"

run_app '/uninstall
y
n
/quit
'
assert_says 'no at the second prompt leaves it alone' "$APP_OUT" 'Left as it is'
assert_there 'and the app is still there too' "$APP_COPY/chat.sh"

# EOF is not consent. The pipe closing mid-confirmation must read as no, the
# same way it does for /update.
run_app '/uninstall
'
assert_there 'a closed pipe is not a yes' "$APP_COPY/chat.sh"

# /remove is the alias people reach for first.
run_app '/remove
n
/quit
'
assert_says 'the alias reaches the same command' "$APP_OUT" 'Uninstall D-Pad Chat?'

# Off the device this is a checkout, and a checkout is not something to delete
# from a chat prompt.
run_app '/uninstall
y
y
/quit
' "$WORK_DIR/no-such-sysdir"
assert_says 'a checkout is refused' "$APP_OUT" 'only runs on the device'
assert_there 'and is left alone' "$APP_COPY/chat.sh"

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
