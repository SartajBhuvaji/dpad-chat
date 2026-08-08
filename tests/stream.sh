#!/bin/sh
# Streaming tests.
#
# The point of streaming is that tokens reach the screen before the response is
# complete, so the interesting assertion is about timing, not just content: a
# client that buffered the whole reply and printed it at the end would pass
# every content check here.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
COLS=200

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

hist() {
    jq -r "$2" "$WORK_DIR/$1/history.json" 2>/dev/null || printf 'ERROR'
}

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
        DPAD_STREAM="${STREAM:-true}" \
        "$REPO_ROOT/app/chat.sh" 2>&1
}

# -----------------------------------------------------------------------------

printf 'Running streaming tests\n'
start_mock

# -----------------------------------------------------------------------------
# Content
# -----------------------------------------------------------------------------

out=$(session basic 'hello' '/quit')
assert_says 'a streamed reply reaches the screen' "$out" 'You said: hello'
assert_eq 'a streamed reply is recorded' "$(hist basic '.[-1].role')" 'assistant'
assert_eq 'the transcript holds the whole reply' \
    "$(hist basic '.[-1].content')" 'You said: hello'

out=$(session chunks 'scenario:long' '/quit')
assert_says 'a reply split across many events is reassembled' \
    "$out" 'SigmaStar SSD202D is the system-on-chip'
assert_says 'the tail of a long reply survives' "$out" 'on-package DDR3 memory'

out=$(session lines 'scenario:multiline' '/quit')
assert_says 'newlines inside a stream are kept' "$out" 'first line'
assert_says 'the last line of a stream is kept' "$out" 'third line'

# The reply must be sent back as context on the next turn, exactly as the
# buffered path does. The mock echoes the request body, so the second turn shows
# what the first one left behind.
#
# Asserting on 'You said: hello' would not prove anything here: that text is
# already on screen from the first turn's own reply.
out=$(session ctx 'hello' 'scenario:echo_payload' '/quit')
assert_says 'a streamed request asks for a stream' "$out" '"stream": true'
assert_says 'a streamed reply is sent back as context' "$out" '"role": "assistant"'
assert_eq 'both streamed turns are recorded' "$(hist ctx 'length')" '5'

# -----------------------------------------------------------------------------
# It actually streams
# -----------------------------------------------------------------------------

# Content assertions cannot tell streaming from buffering: a client that
# collected the whole reply and printed it at the end would pass every one of
# them. Only arrival timing distinguishes the two.
#
# tests/arrival.py counts bursts of bytes separated by a pause. The mock waits
# between events, so a streaming client produces roughly one burst per event
# and a buffered one produces a single burst for the reply.

bursts() {
    printf 'scenario:long\n/quit\n' | env \
        COLUMNS="$COLS" NO_COLOR=1 \
        DPAD_DATA_DIR="$WORK_DIR/$1" \
        DPAD_API_KEY='fixture-value-not-a-secret' \
        DPAD_BASE_URL="$MOCK_URL" \
        DPAD_STREAM="$2" \
        "$REPO_ROOT/app/chat.sh" 2>/dev/null |
        python3 "$REPO_ROOT/tests/arrival.py" --gap-ms 10
}

streamed=$(bursts burst_on true)
if [ "${streamed:-0}" -ge 5 ]; then
    pass "output arrives progressively ($streamed bursts)"
else
    fail 'output arrives progressively' \
        "only $streamed burst(s); the reply looks buffered"
fi

# The control. Without it, a broken measurement that reported a high count for
# everything would still show the test above as passing.
buffered=$(bursts burst_off false)
if [ "${buffered:-99}" -lt 5 ]; then
    pass "the buffered path arrives in few bursts ($buffered)"
else
    fail 'the buffered path arrives in few bursts' \
        "$buffered bursts; the measurement cannot tell the paths apart"
fi

# -----------------------------------------------------------------------------
# Failures
# -----------------------------------------------------------------------------

# An error is a plain JSON body, not events. It must be reported rather than
# printed as though it were the reply.
out=$(session unauth 'scenario:unauthorized' '/quit')
assert_says 'a 401 during streaming is reported' "$out" 'Invalid API key'
refute_says 'the error body is not printed as a reply' "$out" '"error"'
assert_eq 'a failed stream leaves the transcript clean' "$(hist unauth 'length')" '1'

out=$(session servererr 'scenario:server_error' '/quit')
assert_says 'a 500 during streaming is reported' "$out" 'Server error 500'

# A connection that drops mid-reply has already put text on screen, so the text
# is kept rather than discarded.
out=$(session cut 'scenario:stream_cut' '/quit')
assert_says 'a truncated stream keeps what arrived' "$out" 'this reply stops'

out=$(printf 'hello\n/quit\n' | env \
    COLUMNS="$COLS" NO_COLOR=1 DPAD_DATA_DIR="$WORK_DIR/nonet" \
    DPAD_API_KEY='fixture-value-not-a-secret' \
    DPAD_BASE_URL='http://127.0.0.1:1/v1' DPAD_STREAM=true \
    "$REPO_ROOT/app/chat.sh" 2>&1)
assert_says 'a refused connection is explained while streaming' "$out" 'Check WiFi'

# -----------------------------------------------------------------------------
# The setting
# -----------------------------------------------------------------------------

out=$(STREAM=false session buffered 'hello' '/quit')
assert_says 'streaming can be turned off' "$out" 'You said: hello'
assert_eq 'the buffered path still records replies' \
    "$(hist buffered '.[-1].content')" 'You said: hello'

out=$(session about '/about' '/quit')
assert_says '/about reports the streaming state' "$out" 'stream true'

out=$(STREAM=nonsense session bogus '/about' '/quit')
assert_says 'an invalid stream setting falls back to true' "$out" 'stream true'

# -----------------------------------------------------------------------------
# Folding a streamed reply down to ASCII
# -----------------------------------------------------------------------------

# The reason this is done in jq rather than in the shell. The mock splits the
# reply mid-character - "Pokemon" is cut inside the e-acute, so its two bytes
# arrive in different chunks. A filter working on bytes would have to buffer
# across chunks and reassemble; jq is handed decoded text, so by the time the
# fold runs there is nothing left to split.

out=$(session uni 'scenario:unicode' '/quit')
assert_says 'a character split across chunks survives the fold' "$out" 'Pokemon'
assert_says 'and the rest of the reply with it' "$out" 'Cafe - "Here'"'"'s" how...'
assert_says 'accents outside the split too' "$out" 'naive'
assert_says 'and multi-letter spellings' "$out" 'AEsop'

# What goes into the transcript has to match what went on screen, or a resumed
# conversation would redraw the mojibake the fold just removed.
assert_eq 'the transcript keeps the folded text' \
    "$(hist uni '.[-1].content' | head -c 4)" 'Cafe'

# High bytes alone: the escapes the app draws with are control characters and
# belong in the output.
if [ -n "$(hist uni '.[-1].content' | LC_ALL=C tr -dc '\200-\377')" ]; then
    fail 'nothing above ASCII is written to history'
else
    pass 'nothing above ASCII is written to history'
fi

if [ -n "$(printf '%s' "$out" | LC_ALL=C tr -dc '\200-\377')" ]; then
    fail 'nor reaches the screen'
else
    pass 'nor reaches the screen'
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
