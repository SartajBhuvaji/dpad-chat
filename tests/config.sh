#!/bin/sh
# Checks for settings, and for /config.
#
# Two halves. The first drives config_set directly, because it edits a file
# somebody may well have hand-written on a card: comments, spacing, blank lines
# and settings this version has never heard of all have to come back out the
# other side. Losing a comment somebody typed on a handheld is not a fair price
# for changing a number, and nothing else in the suite would notice.
#
# The second drives /config through the app, which is the only way to establish
# that a setting changed at the prompt is still changed after a restart.

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

printf 'Running config tests\n'

CFG="$WORK_DIR/settings.cfg"

# config_set against a file staged by $1, setting $2 to $3, printing the file
# afterwards. Run in a subshell so the module's variables do not leak.
setting() {
    _s_stage="$1"
    shift

    rm -f "$CFG"
    [ "$_s_stage" = '-' ] || printf '%s' "$_s_stage" >"$CFG"

    (
        # shellcheck source=../app/lib/common.sh
        . "$REPO_ROOT/app/lib/common.sh"
        # shellcheck source=../app/lib/config.sh
        . "$REPO_ROOT/app/lib/config.sh"

        CONFIG_FILE="$CFG"
        config_set "$1" "$2" || printf 'WRITE-FAILED\n'
    )

    cat "$CFG" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Editing the file
# -----------------------------------------------------------------------------

printf '\nEditing the settings file\n'

assert_eq 'a missing file is created' "$(setting - model gpt-4o)" 'model=gpt-4o'

assert_eq 'an existing setting is replaced in place' \
    "$(setting 'model=gpt-4o-mini
' model gpt-4o)" 'model=gpt-4o'

assert_eq 'a new setting is appended' \
    "$(setting 'model=gpt-4o
' stream false)" 'model=gpt-4o
stream=false'

# The whole reason this is not `grep -v` and an append.
STAGED='# My settings. Do not lose this line.

api_key = sk-secret

# The model to ask
model = gpt-4o-mini
stream=true
future_setting=whatever
'

out=$(setting "$STAGED" model gpt-4o)
assert_contains 'comments survive' "$out" '# My settings. Do not lose this line.'
assert_contains 'and so do comments between settings' "$out" '# The model to ask'
assert_contains 'other settings survive' "$out" 'api_key = sk-secret'
assert_contains 'and their hand-edited spacing with them' "$out" 'api_key = sk-secret'
assert_contains 'settings this version has never heard of survive' \
    "$out" 'future_setting=whatever'
assert_contains 'the target is rewritten' "$out" 'model=gpt-4o'
assert_not_contains 'and its old value is gone' "$out" 'gpt-4o-mini'

# A blank line is not a KEY=VALUE line and must not be swallowed.
assert_eq 'blank lines are kept' "$(printf '%s' "$out" | grep -c '^$')" '2'

# ` key = value ` is what a file edited on a desktop tends to look like, and
# the loader tolerates it - so the writer has to recognise it rather than
# append a second line for a key that is already set. The line it rewrites
# comes back canonical; every line it does not touch keeps its own spacing,
# which the api_key assertion above covers.
assert_eq 'a spaced key is matched, not duplicated' \
    "$(setting '  stream  =  true
' stream false)" 'stream=false'

# -----------------------------------------------------------------------------

printf '\nAwkward files\n'

# A comment mentioning the setting is still a comment.
assert_eq 'a commented-out setting is left alone' \
    "$(setting '#model=gpt-4o-mini
' model gpt-4o)" '#model=gpt-4o-mini
model=gpt-4o'

# The loader takes the last of a duplicated key, so leaving the second would
# silently undo the write.
assert_eq 'a duplicated key collapses to one' \
    "$(setting 'model=a
stream=true
model=b
' model gpt-4o)" 'model=gpt-4o
stream=true'

# A file with no trailing newline is what an editor that does not add one
# leaves. The last line still has to be read.
assert_eq 'a missing trailing newline is handled' \
    "$(printf 'model=old' >"$CFG" && setting "$(cat "$CFG")" model gpt-4o)" \
    'model=gpt-4o'

assert_eq 'a value with spaces round-trips' \
    "$(setting - system_prompt 'Be brief. Use plain text.')" \
    'system_prompt=Be brief. Use plain text.'

assert_eq 'an empty value is written as empty' "$(setting - suggest '')" 'suggest='

# Nothing is left behind on the way through, and the file is never a partial
# write: it is built beside the target and moved over it.
setting 'model=a
' model b >/dev/null
if [ ! -e "$CFG.new" ]; then
    pass 'no temporary file is left behind'
else
    fail 'no temporary file is left behind'
fi

# The file holds the API key. FAT32 keeps none of this, but a card imaged onto
# a real filesystem does, and it costs nothing to be right.
if [ "$(id -u 2>/dev/null || echo 0)" != '0' ]; then
    # find rather than parsing ls, which shellcheck rightly dislikes and which
    # differs between implementations anyway.
    if [ -n "$(find "$CFG" -perm 0600 2>/dev/null)" ]; then
        pass 'the file is written private'
    else
        fail 'the file is written private' 'the mode is not 600'
    fi
else
    printf '  skipped: running as root, where the mode says less\n'
fi

# -----------------------------------------------------------------------------
# /config, through the app
# -----------------------------------------------------------------------------

printf '\n/config at the prompt\n'

DATA="$WORK_DIR/data"

# Feeds commands to the app and prints what it said. The data directory is kept
# between calls on purpose in the persistence case below.
app() {
    printf '%s\n/quit\n' "$1" |
        COLUMNS=53 LINES=29 DPAD_DATA_DIR="$DATA" NO_COLOR=1 \
            "$REPO_ROOT/app/chat.sh" 2>&1
}

fresh() {
    rm -rf "$DATA"
    app "$1"
}

out=$(fresh '/config')
assert_contains 'it lists the model' "$out" 'model'
assert_contains 'with its value' "$out" 'gpt-4o-mini'
assert_contains 'and the key, redacted' "$out" 'api_key'
assert_contains 'and says how to change one' "$out" '/config <name> <value>'

# The point of the whole command: a value reached without typing one.
out=$(fresh '/config stream')
assert_contains 'a bare name cycles' "$out" 'stream  true -> false'

out=$(fresh '/config max_tokens')
assert_contains 'and so does a number' "$out" 'max_tokens  512 -> 1024'

out=$(fresh '/config model')
assert_contains 'and the model' "$out" 'model  gpt-4o-mini -> gpt-4o'

out=$(fresh '/config max_tokens 4096')
assert_contains 'a value can be given outright' "$out" 'max_tokens  512 -> 4096'

# Off the end of the cycle list, which is where a value set by hand also lands.
out=$(fresh '/config model zz-unknown
/config model')
assert_contains 'an unlisted value cycles to the first' \
    "$out" 'model  zz-unknown -> gpt-4o-mini'

# -----------------------------------------------------------------------------

printf '\nRefusing\n'

out=$(fresh '/config stream yes')
assert_contains 'a bad boolean is refused' "$out" 'not a value stream can take'
assert_contains 'and says what would work' "$out" 'Use true or false'

out=$(fresh '/config max_tokens -5')
assert_contains 'a negative number is refused' "$out" 'not a value max_tokens can take'

out=$(fresh '/config max_tokens abc')
assert_contains 'and so is text' "$out" 'not a value max_tokens can take'

# A real setting, just not one worth typing on a d-pad. Saying where it lives
# beats "unknown", which reads as a typo.
out=$(fresh '/config base_url')
assert_contains 'a file-only setting says so' "$out" 'not editable here'
assert_contains 'and where to change it' "$out" 'settings.cfg'

out=$(fresh '/config nonsense')
assert_contains 'an unknown name is reported' "$out" 'No setting called nonsense'

# -----------------------------------------------------------------------------

printf '\nPersistence\n'

rm -rf "$DATA"
app '/config stream' >/dev/null
out=$(app '/about')
assert_contains 'a change survives a restart' "$out" 'stream   false'

out=$(app '/config')
assert_contains 'and reads back from the file' "$out" 'false'

# -----------------------------------------------------------------------------

printf '\nThe API key\n'

# The REPL puts every accepted line into the recall list and leaves it on
# screen, so a key given as an argument would be one press of Up away. The
# argument is ignored and the key asked for separately instead.
rm -rf "$DATA"
out=$(app '/config api_key sk-should-not-be-taken')
assert_not_contains 'a key given inline is not stored' \
    "$(cat "$DATA/settings.cfg" 2>/dev/null)" 'sk-should-not-be-taken'
assert_contains 'it asks for the key instead' "$out" 'key>'

# Piped, so the editor takes its fallback path and the "line" is whatever comes
# next - here, /quit. What matters is that nothing was written.
assert_not_contains 'and nothing of it reaches the settings file' \
    "$(cat "$DATA/settings.cfg" 2>/dev/null)" 'should-not-be-taken'

rm -rf "$DATA"
out=$(printf '/config api_key\nsk-test-0123456789abcdef\n/quit\n' |
    COLUMNS=53 LINES=29 DPAD_DATA_DIR="$DATA" NO_COLOR=1 \
        "$REPO_ROOT/app/chat.sh" 2>&1)
assert_contains 'a key entered at the prompt is stored' \
    "$(cat "$DATA/settings.cfg" 2>/dev/null)" 'api_key=sk-test-0123456789abcdef'
assert_not_contains 'and is never echoed in full' "$out" 'sk-test-0123456789abcdef'
assert_contains 'only redacted' "$out" 'sk-tes'

rm -rf "$DATA"
out=$(printf '/config api_key\n\n/quit\n' |
    COLUMNS=53 LINES=29 DPAD_DATA_DIR="$DATA" NO_COLOR=1 \
        "$REPO_ROOT/app/chat.sh" 2>&1)
assert_contains 'an empty answer changes nothing' "$out" 'the key is unchanged'

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
