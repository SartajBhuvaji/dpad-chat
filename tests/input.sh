#!/bin/sh
# Checks for the line editor.
#
# Two halves, because the module has two modes. The piped half exercises the
# fallback, which is what the rest of the suite and `echo /about | simulate.sh`
# run through. The terminal half drives a real pty via tests/keys.py, because
# raw mode, echo and escape sequences do not exist without one - and those are
# precisely the parts that were broken on the device.

# Resolve sourced files relative to this script. Must precede the first command
# to apply file-wide.
# shellcheck source-path=SCRIPTDIR

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

printf 'Running input tests\n'

ESC=$(printf '\033')

# -----------------------------------------------------------------------------
# Piped input: the fallback
# -----------------------------------------------------------------------------

printf '\nFalling back without a terminal\n'

# Run in a subshell so the module's variables do not leak between cases.
piped() {
    (
        # shellcheck source=../app/lib/input.sh
        . "$REPO_ROOT/app/lib/input.sh"
        input_init
        if input_readline; then
            printf '0:%s' "$INPUT_LINE"
        else
            printf '1:%s' "$INPUT_LINE"
        fi
    )
}

assert_eq 'a piped line is read' "$(printf 'hello\n' | piped)" '0:hello'
assert_eq 'end of input is reported' "$(printf '' | piped)" '1:'
assert_eq 'spacing is left alone' "$(printf '  two words  \n' | piped)" '0:  two words  '
assert_eq 'a backslash is not an escape' "$(printf 'a\\b\n' | piped)" '0:a\b'

# The bug this whole module exists for: without a terminal there is nothing to
# put into raw mode, so the bytes are taken literally rather than parsed.
assert_eq 'escapes are literal when piped' \
    "$(printf 'a\033[Hb\n' | piped)" "0:a${ESC}[Hb"

assert_eq 'no terminal means no raw mode' \
    "$(printf 'x\n' | (
        # shellcheck source=../app/lib/input.sh
        . "$REPO_ROOT/app/lib/input.sh"
        input_init
        printf '%s' "$INPUT_TTY"
    ))" '0'

# -----------------------------------------------------------------------------
# A real terminal
# -----------------------------------------------------------------------------

printf '\nReading from a terminal\n'

DRIVER="$WORK_DIR/driver.sh"
cat >"$DRIVER" <<'DRIVER_EOF'
#!/bin/sh
set -eu
# shellcheck source=/dev/null
. "$REPO_ROOT/app/lib/input.sh"
input_init

before=$(stty -g)
if input_readline; then
    rc=0
else
    rc=1
fi
after=$(stty -g)

{
    printf 'rc=%s\n' "$rc"
    printf 'raw=%s\n' "$INPUT_TTY"
    if [ "$before" = "$after" ]; then
        printf 'tty=restored\n'
    else
        printf 'tty=changed\n'
    fi
    printf 'line=%s\n' "$INPUT_LINE"
} >"$DRIVER_OUT"
DRIVER_EOF
chmod +x "$DRIVER"

DRIVER_OUT="$WORK_DIR/driver.out"
export REPO_ROOT DRIVER_OUT

# Types the given keystrokes at a pty and leaves the outcome in KEYS_RC,
# KEYS_LINE and KEYS_ECHO. KEYS_ECHO is everything the editor drew, with none
# of the kernel's own echo mixed in; see tests/keys.py for how that is arranged.
keys() {
    : >"$DRIVER_OUT"
    KEYS_ECHO=$("$REPO_ROOT/tests/keys.py" --input "$1" -- "$DRIVER" 2>/dev/null) || :
    KEYS_RC=$(sed -n 's/^rc=//p' "$DRIVER_OUT")
    KEYS_LINE=$(sed -n 's/^line=//p' "$DRIVER_OUT")
    KEYS_TTY=$(sed -n 's/^tty=//p' "$DRIVER_OUT")
    KEYS_RAW=$(sed -n 's/^raw=//p' "$DRIVER_OUT")
}

if ! command -v python3 >/dev/null 2>&1; then
    printf '  skipped: python3 not installed\n'
elif ! keys 'probe\r' || [ "$KEYS_LINE" != 'probe' ]; then
    printf '  skipped: no pseudo-terminal available here\n'
else
    assert_eq 'a typed line is read' "$KEYS_LINE" 'probe'
    assert_eq 'the terminal was taken raw' "$KEYS_RAW" '1'
    assert_eq 'the terminal is handed back' "$KEYS_TTY" 'restored'
    assert_eq 'the editor draws what was typed' "$KEYS_ECHO" "$(printf 'probe\r\n')"

    # Issue #19. Home is `ESC [ H`, and in canonical mode all four bytes were
    # echoed and appended. It must now leave no trace at all.
    keys 'ab\033[Hcd\r'
    assert_eq 'Home does not reach the message' "$KEYS_LINE" 'abcd'
    assert_not_contains 'Home draws nothing' "$KEYS_ECHO" "$ESC"
    assert_not_contains 'no stray bracket from Home' "$KEYS_ECHO" '['

    # The other form of the same key, sent depending on terminal mode.
    keys 'ab\033[1~cd\r'
    assert_eq 'the other Home encoding is dropped too' "$KEYS_LINE" 'abcd'
    assert_not_contains 'and it draws nothing either' "$KEYS_ECHO" '~'

    # Not bound until their own issues, but they must already be consumed
    # whole rather than typed. #20, #21 and #22 give them behaviour.
    keys 'ab\033[3~\r'
    assert_eq 'Del is consumed, not typed' "$KEYS_LINE" 'ab'
    keys 'ab\033[A\033[B\033[C\033[D\r'
    assert_eq 'arrow keys are consumed, not typed' "$KEYS_LINE" 'ab'
    assert_not_contains 'arrow keys draw nothing' "$KEYS_ECHO" "$ESC"

    # Cursor keys arrive as SS3 rather than CSI when the terminal is in
    # application mode, which is a property of the mode and not of the key.
    keys 'ab\033OAcd\r'
    assert_eq 'the SS3 form is consumed too' "$KEYS_LINE" 'abcd'

    # A parameterised sequence: the digits and the separator are parameters,
    # and the letter ends it. Stopping at the wrong byte would leave the rest
    # to be typed.
    keys 'a\033[1;5Cb\r'
    assert_eq 'parameters are part of the sequence' "$KEYS_LINE" 'ab'

    keys 'x\033[38;5;120my\r'
    assert_eq 'a long parameter list is consumed' "$KEYS_LINE" 'xy'

    # Backspace still works exactly as the line discipline made it work. This
    # is deliberately unchanged here; erasing across a wrapped row is #20.
    keys 'abc\177\r'
    assert_eq 'backspace removes the last character' "$KEYS_LINE" 'ab'
    assert_contains 'backspace rubs the character out' "$KEYS_ECHO" "$(printf 'c\b \b')"

    keys '\177\177x\r'
    assert_eq 'backspace on an empty line is harmless' "$KEYS_LINE" 'x'

    # Ctrl-D keeps the meaning the line discipline gave it, so quitting over
    # SSH still works.
    keys '\004'
    assert_eq 'Ctrl-D on an empty line ends input' "$KEYS_RC" '1'

    keys 'kept\004\r'
    assert_eq 'Ctrl-D mid-line does not end input' "$KEYS_RC" '0'
    assert_eq 'and does not disturb the line' "$KEYS_LINE" 'kept'

    # An unbound control byte - Ctrl-G here - would ring the bell or corrupt
    # the display if it were echoed.
    keys 'a\007b\r'
    assert_eq 'unbound control bytes are ignored' "$KEYS_LINE" 'ab'
    assert_eq 'and are not drawn' "$KEYS_ECHO" "$(printf 'ab\r\n')"

    keys 'a\tb\r'
    assert_eq 'tab is not typed into the line' "$KEYS_LINE" 'ab'

    # Enter arrives as CR from the terminal and as LF through some paths;
    # both submit.
    keys 'crlf\n'
    assert_eq 'a newline submits as well' "$KEYS_LINE" 'crlf'

    keys '\r'
    assert_eq 'an empty line is a line, not end of input' "$KEYS_RC" '0'
    assert_eq 'and it is empty' "$KEYS_LINE" ''

    # The other way input ends on a terminal - `st` closing - arrives as
    # SIGHUP and kills the shell outright, so there is no return value left to
    # assert on. The end-of-input path itself is covered by Ctrl-D above and by
    # the piped cases.

    # ESC followed by an ordinary key is Alt-key: unbound, so the whole thing
    # goes, rather than the ESC being dropped and the letter typed.
    keys 'a\033zb\r'
    assert_eq 'an Alt-key combination is dropped whole' "$KEYS_LINE" 'ab'

    # Without a ceiling on the sequence length a terminal stuck mid-sequence
    # would spin here forever.
    keys 'a\033[111111111111111111111111Zb\r'
    assert_eq 'an overlong sequence still terminates' "$KEYS_RC" '0'
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
