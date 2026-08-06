#!/bin/sh
# Checks for the pinned bars and the waiting indicator.
#
# These source screen.sh directly rather than driving chat.sh: the bars only
# render to a terminal, and the test harness is a pipe. What is verifiable
# without a tty is the geometry, which is exactly the part that breaks when the
# column count turns out not to be 40.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

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

assert_len() {
    if [ "${#2}" -eq "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected length $3, got ${#2} for '$2'"
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

printf 'Running screen tests\n'

NO_COLOR=1
export NO_COLOR

# shellcheck source=../app/lib/ui.sh
. "$REPO_ROOT/app/lib/ui.sh"
# shellcheck source=../app/lib/screen.sh
. "$REPO_ROOT/app/lib/screen.sh"

ui_init
UI_COLS=40
CFG_MODEL='gpt-4o-mini'
SCREEN_STATUS='ready'

# --- geometry ----------------------------------------------------------------

assert_len 'compose fills the width exactly' "$(_screen_compose ' left' 'right ')" 40
assert_len 'compose fills a narrow width' "$(UI_COLS=20 _screen_compose ' a' 'b ')" 20

long=' D-Pad Chat  a-very-long-model-name-that-overflows'
assert_len 'compose trims the left side to fit' "$(_screen_compose "$long" 'x ')" 40
assert_contains 'compose keeps the right side intact' \
    "$(_screen_compose "$long" 'READY ')" 'READY '

assert_len 'field is padded to its fixed width' "$(_screen_field 'ready')" 8
assert_eq 'field is right-aligned' "$(_screen_field 'ready')" '   ready'
assert_len 'field truncates an over-long value' "$(_screen_field 'disconnected')" 8

assert_eq 'fit leaves short text alone' "$(_screen_fit 'abc' 10)" 'abc'
assert_eq 'fit truncates to the limit' "$(_screen_fit 'abcdefgh' 3)" 'abc'
assert_eq 'fit returns empty at zero width' "$(_screen_fit 'abc' 0)" ''
assert_eq 'fit returns empty at negative width' "$(_screen_fit 'abc' -5)" ''

# --- bars --------------------------------------------------------------------

assert_len 'state bar is exactly one row wide' "$(_screen_state_bar)" 40
assert_len 'keys bar is exactly one row wide' "$(_screen_keys_bar)" 40
assert_contains 'state bar names the app' "$(_screen_state_bar)" 'D-Pad Chat'
assert_contains 'state bar shows the model' "$(_screen_state_bar)" 'gpt-4o-mini'
assert_contains 'state bar shows the status' "$(_screen_state_bar)" 'ready'
assert_contains 'keys bar shows the keyboard toggle' "$(_screen_keys_bar)" 'X keys'
assert_contains 'keys bar shows how to quit' "$(_screen_keys_bar)" 'Select quit'

SCREEN_STATUS='offline'
assert_contains 'state bar reflects a changed status' "$(_screen_state_bar)" 'offline'
assert_len 'state bar width survives a status change' "$(_screen_state_bar)" 40
SCREEN_STATUS='ready'

overflow_model='gpt-4o-mini-with-an-absurdly-long-suffix'
assert_len 'state bar width survives a long model name' \
    "$(CFG_MODEL="$overflow_model" _screen_state_bar)" 40

# --- rows --------------------------------------------------------------------

assert_eq 'rows come from LINES when set' "$(LINES=30 _screen_detect_rows)" '30'
assert_eq 'rows fall back when LINES is not a number' \
    "$(LINES=tall _screen_detect_rows)" '30'
assert_eq 'rows fall back when LINES is empty' "$(LINES='' _screen_detect_rows)" '30'

# --- spinner -----------------------------------------------------------------

_spin_glyph 0
assert_eq 'spinner frame 0' "$SPIN_GLYPH" '-'
_spin_glyph 1
assert_eq 'spinner frame 1' "$SPIN_GLYPH" '\'
_spin_glyph 2
assert_eq 'spinner frame 2' "$SPIN_GLYPH" '|'
_spin_glyph 3
assert_eq 'spinner frame 3' "$SPIN_GLYPH" '/'
_spin_glyph 4
assert_eq 'spinner wraps around' "$SPIN_GLYPH" '-'

# --- lifecycle without a terminal --------------------------------------------

# The harness is a pipe, so this is the path the tests themselves run through:
# nothing may be drawn and no background process may be left behind.
# Redirected to a file rather than captured with $(...): a command substitution
# runs in a subshell, and the SCREEN_* variables set below would not survive it.
screen_init >"$WORK_DIR/init.out" 2>&1
assert_eq 'init draws nothing without a terminal' "$(cat "$WORK_DIR/init.out")" ''
assert_eq 'bars are disabled without a terminal' "$SCREEN_BARS" '0'
assert_eq 'spinner is disabled without a terminal' "$SPIN_TTY" '0'

spin_start 2>"$WORK_DIR/spin.out"
assert_eq 'spin_start starts no process without a terminal' "$SPIN_PID" ''
assert_contains 'spin_start still reports progress when piped' \
    "$(cat "$WORK_DIR/spin.out")" 'thinking'
assert_not_contains 'spin_start emits no escapes when piped' \
    "$(cat "$WORK_DIR/spin.out")" '['

spin_stop 2>"$WORK_DIR/stop.out"
pass 'spin_stop is safe when nothing was started'
assert_eq 'spin_stop emits no escapes when piped' "$(cat "$WORK_DIR/stop.out")" ''

screen_teardown
screen_teardown
pass 'teardown is safe to call twice'

screen_status 'offline' >"$WORK_DIR/status.out" 2>&1
assert_eq 'status draws nothing without bars' "$(cat "$WORK_DIR/status.out")" ''
assert_eq 'status is recorded even with no bars to draw' "$SCREEN_STATUS" 'offline'

# --- tick detection ----------------------------------------------------------

# The tick decides whether the indicator can animate at all. Whichever branch
# this machine takes, the pair must stay consistent: a fast tick without the
# matching frame rate would make the elapsed count run at the wrong speed.
_spin_init_tick
case "$SPIN_TICK" in
    0.1) assert_eq 'a fractional tick runs at ten frames' "$SPIN_FPS" '10' ;;
    1) assert_eq 'a whole-second tick runs at one frame' "$SPIN_FPS" '1' ;;
    *) fail 'tick is one of the two supported values' "got '$SPIN_TICK'" ;;
esac

if sleep 0.1 2>/dev/null; then
    assert_eq 'fractional sleep is detected where it works' "$SPIN_TICK" '0.1'
else
    assert_eq 'fractional sleep absent falls back to one second' "$SPIN_TICK" '1'
fi

# Detection must not leave state behind in the data directory.
assert_eq 'tick detection writes nothing to the data directory' \
    "$(ls "$WORK_DIR" 2>/dev/null | grep -c 'spin-tick' || true)" '0'

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
