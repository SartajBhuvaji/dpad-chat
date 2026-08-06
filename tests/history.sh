#!/bin/sh
# Conversation history tests.
#
# Two kinds of assertion, deliberately kept apart:
#
#   - What was *sent*: the mock's echo_payload scenario returns the request body
#     as its reply, so the messages array is directly observable.
#   - What was *kept*: jq against the transcript on disk.
#
# Grepping the session's console output cannot do either job. A reply printed on
# turn one is still on screen at turn four, so "the oldest turn was dropped"
# would look false even when it was dropped.

set -eu

# Transcript mechanics are independent of transport, so the buffered path is
# pinned for speed and determinism. tests/stream.sh asserts that a streamed
# reply is recorded the same way.

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
COLS=200 # wide, so JSON echoed back is not wrapped mid-token

TESTS_RUN=0
TESTS_FAILED=0

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
MOCK_PID=''

cleanup() {
    [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null || :
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

start_mock() {
    python3 "$REPO_ROOT/tools/mockapi.py" \
        --port 0 --port-file "$WORK_DIR/port" >"$WORK_DIR/mock.log" 2>&1 &
    MOCK_PID=$!
    waited=0
    while [ ! -s "$WORK_DIR/port" ]; do
        [ "$waited" -lt 50 ] || {
            printf 'mock did not start\n' >&2
            exit 1
        }
        sleep 0.1
        waited=$((waited + 1))
    done
    MOCK_URL="http://127.0.0.1:$(cat "$WORK_DIR/port")/v1"
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

# Console output is wrapped and its runs of spaces are collapsed, so assertions
# on it are made against the flattened form.
flatten() {
    printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}

assert_says() {
    case "$(flatten "$2")" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "expected to find: $3" ;;
    esac
}

refute_says() {
    case "$(flatten "$2")" in
        *"$3"*) fail "$1" "did not expect: $3" ;;
        *) pass "$1" ;;
    esac
}

assert_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected '$3', got '$2'"
    fi
}

# Query the transcript a session left behind.
hist() {
    jq -r "$2" "$WORK_DIR/$1/history.json" 2>/dev/null || printf 'ERROR'
}

# Run a whole session: every argument after the data directory is one input line.
session() {
    dir="$1"
    shift
    for line in "$@"; do
        printf '%s\n' "$line"
    done | env \
        COLUMNS="$COLS" NO_COLOR=1 \
        DPAD_DATA_DIR="$WORK_DIR/$dir" \
        DPAD_API_KEY='fixture-value-not-a-secret' \
        DPAD_BASE_URL="$MOCK_URL" \
        DPAD_STREAM=false \
        DPAD_HISTORY_MESSAGES="${LIMIT:-10}" \
        "$REPO_ROOT/app/chat.sh" 2>&1
}

# -----------------------------------------------------------------------------

printf 'Running history tests\n'
start_mock

# -----------------------------------------------------------------------------
# The transcript is what gets sent
# -----------------------------------------------------------------------------

out=$(session ctx 'what is a miyoo mini' 'scenario:echo_payload' '/quit')
assert_says 'the earlier question is resent as context' "$out" 'what is a miyoo mini'
assert_says 'the earlier reply is resent as context' "$out" 'You said: what is a miyoo mini'
assert_says 'the system prompt leads the request' "$out" '"role": "system"'
assert_says 'assistant turns are labelled' "$out" '"role": "assistant"'

assert_eq 'both turns are recorded' "$(hist ctx 'length')" '5'
assert_eq 'the transcript opens with the system prompt' \
    "$(hist ctx '.[0].role')" 'system'
assert_eq 'the first user turn is kept verbatim' \
    "$(hist ctx '.[1].content')" 'what is a miyoo mini'

# A first message must carry the system prompt and nothing else, or the model is
# handed a conversation that never happened.
out=$(session fresh 'scenario:echo_payload' '/quit')
refute_says 'a fresh session sends no prior turns' "$out" 'You said:'

# -----------------------------------------------------------------------------
# Trimming
# -----------------------------------------------------------------------------

LIMIT=4 session trim 'one' 'two' 'three' 'four' '/quit' >/dev/null

assert_eq 'the transcript is capped at the limit' "$(hist trim 'length')" '5'
# Losing the system prompt would silently change the model's behaviour, so it
# has to survive no matter how long the conversation runs.
assert_eq 'the system prompt survives trimming' "$(hist trim '.[0].role')" 'system'
assert_eq 'the oldest turn is dropped' \
    "$(hist trim '[.[] | select(.content == "one")] | length')" '0'
assert_eq 'the newest turn is kept' \
    "$(hist trim '[.[] | select(.content == "four")] | length')" '1'

out=$(LIMIT=4 session trimabout 'one' 'two' 'three' 'four' '/about' '/quit')
assert_says '/about reports the history size' "$out" 'history 4 of 4 msgs'

# -----------------------------------------------------------------------------
# Failed turns
# -----------------------------------------------------------------------------

session rollback 'hello' 'scenario:server_error' '/quit' >/dev/null
assert_eq 'a failed turn leaves the transcript untouched' \
    "$(hist rollback 'length')" '3'
assert_eq 'the unanswered question is not kept' \
    "$(hist rollback '[.[] | select(.content == "scenario:server_error")] | length')" '0'
assert_eq 'the last turn is still the earlier answer' \
    "$(hist rollback '.[-1].role')" 'assistant'

# The session must survive the failure and keep answering.
out=$(session rollback2 'scenario:server_error' 'hello' '/quit')
assert_says 'the session continues after a failure' "$out" 'You said: hello'

# -----------------------------------------------------------------------------
# /clear
# -----------------------------------------------------------------------------

out=$(session new 'hello' '/clear' '/quit')
assert_says '/clear reports what it cleared' "$out" '2 messages cleared'
assert_eq '/clear empties the transcript' "$(hist new 'length')" '1'
assert_eq '/clear keeps the system prompt' "$(hist new '.[0].role')" 'system'

# Clearing is now the only way to lose a chat that would have survived a
# restart, so the outgoing one is kept.
if [ -s "$WORK_DIR/new/history.json.prev" ]; then
    pass '/clear keeps the previous chat on disk'
else
    fail '/clear keeps the previous chat on disk'
fi
assert_says '/clear says where the copy went' "$out" 'history.json.prev'

out=$(session shortc 'hello' '/c' '/quit')
assert_says '/c is an alias for /clear' "$out" '2 messages cleared'
assert_eq '/c empties the transcript' "$(hist shortc 'length')" '1'

out=$(session new2 '/clear' '/quit')
assert_says '/clear on an empty chat says so' "$out" 'Already a new chat'

# -----------------------------------------------------------------------------
# Persistence
# -----------------------------------------------------------------------------

session persist 'remember this' '/quit' >/dev/null
assert_eq 'the first session recorded its turn' "$(hist persist 'length')" '3'

out=$(session persist '/about' '/quit')
assert_says 'a restart resumes the conversation' "$out" 'history 2 of'
assert_eq 'the transcript survives a restart' "$(hist persist 'length')" '3'
assert_says 'the resumed turn is shown on screen' "$out" 'remember this'
assert_says 'a resumed session says so' "$out" '-- resumed'

# The context must still be sent, not merely displayed.
out=$(session persist 'scenario:echo_payload' '/quit')
assert_says 'a resumed conversation is sent as context' "$out" 'remember this'

# The system prompt lives in settings, so editing it has to take effect on the
# next launch rather than waiting for a new conversation.
out=$(DPAD_SYSTEM_PROMPT_UNUSED=1 session persist '/quit')
assert_eq 'the system prompt stays at index 0' "$(hist persist '.[0].role')" 'system'

# A half-written file survives a battery pull; it must not take the app down.
mkdir -p "$WORK_DIR/corrupt"
printf '{"not": "an array"' >"$WORK_DIR/corrupt/history.json"
out=$(session corrupt '/about' '/quit')
assert_says 'an unreadable transcript is reported' "$out" 'could not be read'
assert_says 'an unreadable transcript starts a new chat' "$out" 'history 0 of'
if [ -f "$WORK_DIR/corrupt/history.json.corrupt" ]; then
    pass 'the unreadable transcript is kept for inspection'
else
    fail 'the unreadable transcript is kept for inspection'
fi

# Valid JSON that is not a conversation would otherwise fail inside a request,
# where the error is opaque.
mkdir -p "$WORK_DIR/wrongshape"
printf '[{"foo": 1}]' >"$WORK_DIR/wrongshape/history.json"
out=$(session wrongshape '/about' '/quit')
assert_says 'a wrongly shaped transcript is rejected' "$out" 'could not be read'
assert_eq 'a wrongly shaped transcript is replaced' \
    "$(hist wrongshape '.[0].role')" 'system'

# Replay is capped so a long chat cannot push the prompt off the bottom.
session cap 'one' 'two' 'three' 'four' '/quit' >/dev/null
out=$(DPAD_REPLAY_MESSAGES=2 session cap '/quit')
assert_says 'replay reports the cap' "$out" 'showing last 2'
refute_says 'replay omits older turns' "$out" 'You said: one'
assert_says 'replay shows the most recent turn' "$out" 'You said: four'

# -----------------------------------------------------------------------------
# Encoding
# -----------------------------------------------------------------------------

# The transcript is rewritten every turn, so a stray quote would corrupt not one
# request but every request after it.
out=$(session quotes 'say "hi" and it'\''s \ fine' 'scenario:echo_payload' '/quit')
assert_says 'quotes survive the round trip' "$out" 'it'\''s'
refute_says 'the request stays well formed' "$out" 'not valid JSON'
assert_eq 'the awkward turn is stored verbatim' \
    "$(hist quotes '.[1].content')" 'say "hi" and it'\''s \ fine'

if jq -e . "$WORK_DIR/quotes/history.json" >/dev/null 2>&1; then
    pass 'the transcript on disk is valid JSON'
else
    fail 'the transcript on disk is valid JSON'
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
