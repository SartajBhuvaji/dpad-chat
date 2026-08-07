#!/bin/sh
# End-to-end checks for the REPL, driven by piping commands into chat.sh.
#
# These run identically on a development machine and inside the Alpine harness
# (`make test-docker`), which is where they matter: Alpine's busybox ash is the
# closest available stand-in for the device shell.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

# Deliberately not the built-in fallbacks, so a run that ignored COLUMNS and
# LINES entirely would report the defaults and fail rather than pass by
# coincidence.
COLS=40
ROWS=24

TESTS_RUN=0
TESTS_FAILED=0

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
trap 'rm -rf "$WORK_DIR"' EXIT

# Feed stdin to the app and capture everything it prints.
run_app() {
    COLUMNS="$COLS" LINES="$ROWS" DPAD_DATA_DIR="$WORK_DIR/data" NO_COLOR=1 \
        "$REPO_ROOT/app/chat.sh" 2>&1
}

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

assert_contains() {
    name="$1"
    haystack="$2"
    needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "expected to find: $needle" ;;
    esac
}

assert_not_contains() {
    name="$1"
    haystack="$2"
    needle="$3"
    case "$haystack" in
        *"$needle"*) fail "$name" "did not expect: $needle" ;;
        *) pass "$name" ;;
    esac
}

# -----------------------------------------------------------------------------

printf 'Running smoke tests\n'

out=$(printf '/about\n/quit\n' | run_app)
assert_contains '/about reports the version' "$out" 'version'
assert_contains '/about reports the width' "$out" '40 cols'
assert_contains '/about reports the height' "$out" '24 rows'
assert_contains '/about reports a development host' "$out" 'development'

out=$(printf '/help\n/quit\n' | run_app)
assert_contains '/help lists /quit' "$out" '/quit'
assert_contains '/help lists /uninstall' "$out" '/uninstall'
assert_contains '/help explains the keyboard toggle' "$out" 'X toggles the keyboard'

out=$(printf '/?\n/quit\n' | run_app)
assert_contains '/? is an alias for /help' "$out" '/about'

out=$(printf '/nope\n/quit\n' | run_app)
assert_contains 'unknown commands are reported' "$out" 'Unknown command: /nope'

# Regression: an unquoted /? in the case statement is a glob, and would match
# every other two-character command.
out=$(printf '/x\n/quit\n' | run_app)
assert_contains 'short unknown commands are reported' "$out" 'Unknown command: /x'

# No key is configured here, so plain text stops at the client without opening
# a socket. tests/api.sh covers the request path against the mock server.
out=$(printf 'hello there\n/quit\n' | run_app)
assert_contains 'plain text reaches the responder' "$out" 'No API key set'
assert_contains 'the responder shows progress' "$out" 'thinking'

# Trimming is observable without a network: a padded command still dispatches.
out=$(printf '   /about   \n/quit\n' | run_app)
assert_contains 'padded commands are trimmed and dispatched' "$out" 'version'
assert_not_contains 'a padded command is not treated as chat' "$out" 'Unknown command'

out=$(printf '\n   \n/quit\n' | run_app)
assert_not_contains 'blank lines are ignored' "$out" 'thinking'

# Exit status matters: Onion returns to the Apps menu on any exit, but a
# non-zero code means a stuck process is more likely.
if printf '/quit\n' | run_app >/dev/null 2>&1; then
    pass '/quit exits cleanly'
else
    fail '/quit exits cleanly' "exit status $?"
fi

if printf '' | run_app >/dev/null 2>&1; then
    pass 'EOF exits cleanly'
else
    fail 'EOF exits cleanly' "exit status $?"
fi

# Horizontal space is the scarce resource on a 640x480 panel: anything wider
# than the terminal is silently truncated or hard-wrapped mid-word.
out=$(printf 'hello\n/help\n/about\n/quit\n' | run_app)
longest=$(printf '%s\n' "$out" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
if [ "$longest" -le "$COLS" ]; then
    pass "all output wraps to $COLS columns"
else
    fail "all output wraps to $COLS columns" "longest line was $longest"
fi

# The settings file is the only route a suggestion has into the app, so a key
# missing from the whitelist would reach the user as a warning about their own
# config and no suggestion at all.
mkdir -p "$WORK_DIR/data"
printf 'suggest = I am playing something\n' >"$WORK_DIR/data/settings.cfg"

out=$(printf '/quit\n' | run_app)
assert_not_contains 'suggest is a known setting' "$out" "unknown setting 'suggest'"

# Piped input takes the fallback read, where there is no terminal to draw a
# suggestion on and no key to accept it with. What matters is not that it is
# invisible but that it cannot be sent: nothing is ever asked that the user did
# not type or accept.
out=$(printf 'hello\n/quit\n' | run_app)
assert_not_contains 'and a suggestion never reaches a piped line' \
    "$out" 'I am playing something'

rm -f "$WORK_DIR/data/settings.cfg"

# A session log is the only diagnostic available once the app is on a device.
if [ -f "$WORK_DIR/data/dpad-chat.log" ]; then
    pass 'a session log is written'
else
    fail 'a session log is written' "no log at $WORK_DIR/data/dpad-chat.log"
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
