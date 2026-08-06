#!/bin/sh
# Installer tests.
#
# The transfer itself needs a device, so what is tested here is everything that
# happens around it: argument handling, and the settings merge that decides what
# a reinstall does to a key and to settings chosen on the device.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
INSTALL="$REPO_ROOT/tools/install.sh"

TESTS_RUN=0
TESTS_FAILED=0

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

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
        *) fail "$1" "expected to find: $3" ;;
    esac
}

refute_contains() {
    case "$2" in
        *"$3"*) fail "$1" "did not expect: $3" ;;
        *) pass "$1" ;;
    esac
}

merge() {
    printf '%s\n' "$2" | sh "$INSTALL" --merge-settings "$1"
}

# -----------------------------------------------------------------------------

printf 'Running installer tests\n'

# -----------------------------------------------------------------------------
# First install
# -----------------------------------------------------------------------------

out=$(merge "$WORK_DIR/absent.cfg" 'fixture-value-not-a-secret')
assert_eq 'a first install writes just the key' \
    "$out" 'api_key=fixture-value-not-a-secret'

# -----------------------------------------------------------------------------
# Reinstall over existing settings
# -----------------------------------------------------------------------------

cat >"$WORK_DIR/existing.cfg" <<'EOF'
# tuned on the device
model = gpt-4o-mini
max_tokens = 256
api_key = old-fixture-value
history_messages = 6
EOF

out=$(merge "$WORK_DIR/existing.cfg" 'new-fixture-value')

# Settings chosen on the device must survive a reinstall; losing them would
# silently reset the model and cost the user their tuning.
assert_contains 'the model is preserved' "$out" 'model = gpt-4o-mini'
assert_contains 'max_tokens is preserved' "$out" 'max_tokens = 256'
assert_contains 'history_messages is preserved' "$out" 'history_messages = 6'
assert_contains 'comments are preserved' "$out" '# tuned on the device'
assert_contains 'the new key is written' "$out" 'api_key=new-fixture-value'
refute_contains 'the old key is gone' "$out" 'old-fixture-value'
assert_eq 'exactly one api_key line remains' \
    "$(printf '%s\n' "$out" | grep -c '^[[:space:]]*api_key[[:space:]]*=')" '1'

# A hand-edited file may space the assignment any way at all.
printf 'api_key   =   spaced-out-value\nmodel = keep-me\n' >"$WORK_DIR/spaced.cfg"
out=$(merge "$WORK_DIR/spaced.cfg" 'replacement-value')
refute_contains 'an oddly spaced key is still replaced' "$out" 'spaced-out-value'
assert_contains 'the rest of an odd file survives' "$out" 'model = keep-me'

# A commented-out key is documentation, not a setting, and is left alone.
printf '# api_key = example-from-the-readme\nmodel = keep-me\n' >"$WORK_DIR/commented.cfg"
out=$(merge "$WORK_DIR/commented.cfg" 'replacement-value')
assert_contains 'a commented key is left alone' "$out" '# api_key = example'

# -----------------------------------------------------------------------------
# Rejected input
# -----------------------------------------------------------------------------

if printf '\n' | sh "$INSTALL" --merge-settings "$WORK_DIR/absent.cfg" >/dev/null 2>&1; then
    fail 'an empty key is rejected'
else
    pass 'an empty key is rejected'
fi

# Pasting from a terminal picks up stray whitespace surprisingly often, and the
# result would be a settings file the app cannot parse.
if printf 'has a space\n' | sh "$INSTALL" --merge-settings "$WORK_DIR/absent.cfg" >/dev/null 2>&1; then
    fail 'a key containing a space is rejected'
else
    pass 'a key containing a space is rejected'
fi

if printf 'has\ttab\n' | sh "$INSTALL" --merge-settings "$WORK_DIR/absent.cfg" >/dev/null 2>&1; then
    fail 'a key containing a tab is rejected'
else
    pass 'a key containing a tab is rejected'
fi

# -----------------------------------------------------------------------------
# Argument handling
# -----------------------------------------------------------------------------

if sh "$INSTALL" >/dev/null 2>&1; then
    fail 'no arguments shows usage and fails'
else
    pass 'no arguments shows usage and fails'
fi

out=$(sh "$INSTALL" --help 2>&1)
assert_contains 'help documents --key' "$out" '--key'
assert_contains 'help names the default login' "$out" 'onion'

err=$(sh "$INSTALL" --key /tmp 2>&1 || :)
assert_contains '--key is refused for a card install' "$err" 'only applies to --ssh'

err=$(sh "$INSTALL" --ssh 2>&1 || :)
assert_contains '--ssh without a host is refused' "$err" 'needs a host'

err=$(sh "$INSTALL" --nonsense 2>&1 || :)
assert_contains 'unknown options are refused' "$err" 'unknown option'

err=$(sh "$INSTALL" --key-file "$WORK_DIR/nope" --ssh 1.2.3.4 2>&1 || :)
assert_contains 'a missing key file is reported' "$err" 'no such file'

# -----------------------------------------------------------------------------
# The key never reaches a command line
# -----------------------------------------------------------------------------

# Anything on argv is visible in ps and lands in shell history, so the key has
# to travel by stdin. This asserts the script offers no way to pass it inline.
# The pattern is literal: $2 is being searched for in the source, not expanded.
# shellcheck disable=SC2016
if grep -qE '^\s*--key[[:space:]]*\)[^)]*\$2' "$INSTALL"; then
    fail 'the key cannot be given as an argument'
else
    pass 'the key cannot be given as an argument'
fi

if grep -q 'ControlMaster' "$INSTALL"; then
    pass 'ssh connections are multiplexed'
else
    fail 'ssh connections are multiplexed' 'expected ControlMaster'
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
