#!/bin/sh
# Checks for the reboot tool.
#
# The device half cannot be exercised against a device without restarting one,
# so tools/reboot.sh is split: everything with a decision in it goes into the
# script that is sent, and the restart itself is one word fired separately.
# --print-remote hands over that script, and it is run here against a directory
# standing in for a card, with reboot and sync stubbed.
#
# What that buys is the assertion at the end of the first section: the script
# that runs on somebody's device never restarts it. Nothing else here could
# establish that.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
TOOL="$REPO_ROOT/tools/reboot.sh"

TESTS_RUN=0
TESTS_FAILED=0

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
trap 'rm -rf "$WORK_DIR"' EXIT

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

assert_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected '$3', got '$2'"
    fi
}

assert_contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "expected to find '$3' in '$2'" ;;
    esac
}

assert_not_contains() {
    case "$2" in
        *"$3"*) fail "$1" "did not expect '$3' in '$2'" ;;
        *) pass "$1" ;;
    esac
}

# -----------------------------------------------------------------------------

printf 'Running reboot tests\n'

# A card, and stubs for the three commands the generated script looks for or
# calls. Each records that it ran, so "sync happened" and "nothing restarted"
# are both things this can assert rather than assume.
CARD="$WORK_DIR/card"
STUBS="$WORK_DIR/stubs"
RAN="$WORK_DIR/ran"

SH_PATH=$(command -v sh)
mkdir -p "$WORK_DIR/empty"

# busybox resolves its applets without consulting PATH, so a stub directory
# there can neither shadow `sync` nor hide `reboot`. Two cases below are built
# out of exactly that and are skipped rather than rewritten into something
# weaker - they still run under dash, which is where CI's main job is, and the
# script under test is the same one either way.
#
# This is good news for the tool: a device always has the applet.
if PATH="$WORK_DIR/empty" "$SH_PATH" -c 'command -v reboot' >/dev/null 2>&1; then
    PATH_HIDES_APPLETS=0
else
    PATH_HIDES_APPLETS=1
fi

mkdir -p "$STUBS"
for stub in reboot poweroff sync; do
    cat >"$STUBS/$stub" <<EOF
#!/bin/sh
printf '%s\n' '$stub' >>"\$RAN"
EOF
    chmod +x "$STUBS/$stub"
done

# Runs the generated script against a fresh card. $1 is any options to pass to
# the tool; leave it empty for the defaults.
#
# Prints the script's output followed by its exit status, so a case cannot pass
# by producing the right words and the wrong result.
on_card() {
    rm -rf "$CARD" "$RAN"
    mkdir -p "$CARD/.tmp_update"
    : >"$RAN"

    # The auto-resume file, present unless a case removes it afterwards.
    printf '#!/bin/sh\n/mnt/SDCARD/Emu/MD/launch.sh "Road Rash.zip"\n' \
        >"$CARD/.tmp_update/cmd_to_run.sh"

    run_generated "$1"
}

# The same without the card being an Onion one, and without resetting it.
run_generated() {
    script="$WORK_DIR/remote.sh"

    # shellcheck disable=SC2086
    DPAD_REMOTE_CARD="$CARD" "$TOOL" --print-remote $1 >"$script"

    out=$(RAN="$RAN" PATH="$STUBS:$PATH" sh "$script" 2>&1) && rc=0 || rc=$?
    printf '%s\n:%s' "$out" "$rc"
}

# -----------------------------------------------------------------------------
# What gets sent to the device
# -----------------------------------------------------------------------------

printf '\nWhat gets sent\n'

# A syntax error in the generated script would only surface on a device, at the
# point where the connection is already open.
DPAD_REMOTE_CARD="$CARD" "$TOOL" --print-remote >"$WORK_DIR/syntax.sh"
if sh -n "$WORK_DIR/syntax.sh" 2>/dev/null; then
    pass 'the generated script is valid sh'
else
    fail 'the generated script is valid sh'
fi

if command -v dash >/dev/null 2>&1 && dash -n "$WORK_DIR/syntax.sh" 2>/dev/null; then
    pass 'and valid under dash'
elif command -v dash >/dev/null 2>&1; then
    fail 'and valid under dash'
else
    printf '  skipped: dash not installed\n'
fi

out=$(on_card '')
assert_contains 'auto-resume is cleared' "$out" 'resume: cleared'
assert_contains 'and the card is flushed' "$out" 'sync: ok'
assert_contains 'and it succeeds' "$out" ':0'

if [ ! -f "$CARD/.tmp_update/cmd_to_run.sh" ]; then
    pass 'the auto-resume file is really gone'
else
    fail 'the auto-resume file is really gone'
fi

if [ "$PATH_HIDES_APPLETS" -eq 1 ]; then
    assert_contains 'sync was really called' "$(cat "$RAN")" 'sync'
else
    printf '  skipped: applets here ignore PATH, so sync cannot be observed\n'
fi

# The whole reason the restart is fired separately. If this ever fails, the
# script being sent to somebody's device restarts it before reporting anything,
# and the report is what decides whether the restart should happen at all.
assert_not_contains 'and nothing was restarted by it' "$(cat "$RAN")" 'reboot'
assert_not_contains 'nor powered off' "$(cat "$RAN")" 'poweroff'

# -----------------------------------------------------------------------------
# Auto-resume
# -----------------------------------------------------------------------------

printf '\nAuto-resume\n'

# The difference between a power cycle and a fresh start. Onion replays what
# was running from this file, so leaving it is how the device boots back into
# the game the restart was meant to get rid of.
out=$(on_card '--keep-resume')
assert_contains 'it can be left alone' "$out" 'resume: left alone'
assert_contains 'and that still succeeds' "$out" ':0'

if [ -f "$CARD/.tmp_update/cmd_to_run.sh" ]; then
    pass 'and the file survives'
else
    fail 'and the file survives'
fi

# Nothing was playing, which is the ordinary case for a device sitting at the
# menu. Not an error, and worth saying rather than reporting a clear that did
# not happen.
rm -rf "$CARD" "$RAN"
mkdir -p "$CARD/.tmp_update"
: >"$RAN"
out=$(run_generated '')
assert_contains 'an absent file is not an error' "$out" 'resume: was not set'
assert_contains 'and does not stop the restart' "$out" ':0'

# A read-only card still restarts. It just comes back where it was, which is
# worth saying rather than refusing over.
#
# Made read-only by taking write permission off the directory holding the file,
# which is what a card mounted read-only amounts to. Root ignores that, so the
# case cannot be built there - the busybox harness runs as root.
if [ "$(id -u 2>/dev/null || echo 0)" = '0' ]; then
    printf '  skipped: running as root, which can delete regardless\n'
else
    rm -rf "$CARD" "$RAN"
    mkdir -p "$CARD/.tmp_update"
    : >"$RAN"
    printf 'x\n' >"$CARD/.tmp_update/cmd_to_run.sh"
    chmod a-w "$CARD/.tmp_update"

    out=$(run_generated '')
    assert_contains 'a clear that cannot happen is reported, not fatal' \
        "$out" 'could not be cleared'
    assert_contains 'and the restart still goes ahead' "$out" ':0'

    chmod u+w "$CARD/.tmp_update"
fi

# -----------------------------------------------------------------------------
# Refusing
# -----------------------------------------------------------------------------

printf '\nRefusing\n'

# The check that matters most here. A mistyped host that happens to answer SSH
# would otherwise be restarted, and it could be anything - the difference
# between this and `ssh host reboot` is exactly this test.
rm -rf "$CARD" "$RAN"
mkdir -p "$CARD"
: >"$RAN"
out=$(run_generated '')
assert_contains 'a host that is not an Onion device is refused' "$out" 'not-onion'
assert_contains 'and says so before anything else' "$out" ':4'
assert_eq 'and nothing ran on it' "$(cat "$RAN")" ''

# A device with no reboot applet is not one this can restart, and saying so
# beats a connection that drops for reasons nobody can see.
if [ "$PATH_HIDES_APPLETS" -eq 0 ]; then
    printf '  skipped: applets here ignore PATH, so reboot cannot be hidden\n'
else
    rm -rf "$CARD" "$RAN"
    mkdir -p "$CARD/.tmp_update"
    : >"$RAN"
    script="$WORK_DIR/remote.sh"
    DPAD_REMOTE_CARD="$CARD" "$TOOL" --print-remote >"$script"

    # An empty PATH is enough: the check for the applet comes before anything
    # external is called, so nothing below it needs to be reachable. The shell
    # is named absolutely because it has to be found without one.
    out=$(RAN="$RAN" PATH="$WORK_DIR/empty" "$SH_PATH" "$script" 2>&1) &&
        rc=0 || rc=$?
    assert_contains 'a device with no reboot is refused' "$out" 'missing: no reboot'
    assert_eq 'with its own status' "$rc" '3'
fi

# -----------------------------------------------------------------------------
# Shutting down instead
# -----------------------------------------------------------------------------

printf '\nShutting down instead\n'

out=$(on_card '--off')
assert_contains 'the action can be poweroff' "$out" 'sync: ok'
assert_contains 'and it succeeds' "$out" ':0'
assert_contains 'and poweroff is what was looked for' \
    "$(DPAD_REMOTE_CARD="$CARD" "$TOOL" --print-remote --off)" "ACTION='poweroff'"
assert_contains 'reboot is the default' \
    "$(DPAD_REMOTE_CARD="$CARD" "$TOOL" --print-remote)" "ACTION='reboot'"

# -----------------------------------------------------------------------------
# The command line
# -----------------------------------------------------------------------------

printf '\nThe command line\n'

out=$("$TOOL" 2>&1) && rc=0 || rc=$?
assert_eq 'no host is a usage error' "$rc" '1'
assert_contains 'and prints the usage' "$out" 'tools/reboot.sh'

out=$("$TOOL" --help 2>&1) && rc=0 || rc=$?
assert_eq '--help is not an error' "$rc" '0'
assert_contains 'and warns what is lost' "$out" 'Unsaved game progress is lost'

out=$("$TOOL" --nope 1.2.3.4 2>&1) && rc=0 || rc=$?
assert_eq 'an unknown option is refused' "$rc" '1'
assert_contains 'and names it' "$out" 'unknown option: --nope'

out=$("$TOOL" 1.2.3.4 5.6.7.8 2>&1) && rc=0 || rc=$?
assert_eq 'two hosts are refused' "$rc" '1'

# Nothing about this may happen because a script happened to pipe into it. The
# same rule the app's own confirmations use: a closed pipe is not consent.
out=$(printf '' | "$TOOL" 1.2.3.4 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
    pass 'a closed pipe is not consent'
else
    fail 'a closed pipe is not consent' 'it went ahead'
fi
assert_not_contains 'and nothing was sent' "$out" 'sent'

out=$(printf 'n\n' | "$TOOL" 1.2.3.4 2>&1) && rc=0 || rc=$?
assert_not_contains 'answering no sends nothing either' "$out" 'sent'

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
