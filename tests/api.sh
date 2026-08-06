#!/bin/sh
# Client tests, driven against tools/mockapi.py.
#
# Every failure path in PLAN.md section 8 is exercised here. None of these tests
# touch the real API: they need no key, cost nothing, and are deterministic.
#
# Fixture keys deliberately avoid both the shape and the entropy of a real
# credential: scanners match on the provider's prefix and on random-looking
# strings near key-ish names. A repository that cries wolf on every push trains
# everyone to ignore it.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
COLS=40

TESTS_RUN=0
TESTS_FAILED=0

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
MOCK_PID=''

cleanup() {
    [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null || :
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Harness
# -----------------------------------------------------------------------------

start_mock() {
    python3 "$REPO_ROOT/tools/mockapi.py" \
        --port 0 --port-file "$WORK_DIR/port" >"$WORK_DIR/mock.log" 2>&1 &
    MOCK_PID=$!

    # The port file is written after bind, so waiting on it cannot race startup.
    waited=0
    while [ ! -s "$WORK_DIR/port" ]; do
        if [ "$waited" -ge 50 ]; then
            printf 'mock server did not start:\n' >&2
            cat "$WORK_DIR/mock.log" >&2
            exit 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    MOCK_URL="http://127.0.0.1:$(cat "$WORK_DIR/port")/v1"
}

# Feed one line to the app and return everything it printed.
ask() {
    printf '%s\n/quit\n' "$1" | env \
        COLUMNS="$COLS" \
        NO_COLOR=1 \
        DPAD_DATA_DIR="$WORK_DIR/data" \
        DPAD_API_KEY="${TEST_API_KEY:-fixture-value-not-a-secret}" \
        DPAD_BASE_URL="$MOCK_URL" \
        DPAD_TIMEOUT="${TEST_TIMEOUT:-15}" \
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
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "expected to find: $3" ;;
    esac
}

assert_not_contains() {
    case "$2" in
        *"$3"*) fail "$1" "did not expect: $3" ;;
        *) pass "$1" ;;
    esac
}

# Output is wrapped to 40 columns, so a phrase the app printed may be split
# across lines. These assertions are about what was said, not how it was laid
# out; smoke.sh owns the wrap-width check.
flatten() {
    printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}

assert_says() {
    assert_contains "$1" "$(flatten "$2")" "$3"
}

# Stronger than flattening for secrets: removing all whitespace means a key
# broken across a line boundary is still caught.
strip_ws() {
    printf '%s' "$1" | tr -d '[:space:]'
}

# -----------------------------------------------------------------------------

printf 'Running API tests\n'
start_mock

out=$(ask 'hello')
assert_contains 'a successful reply is rendered' "$out" 'You said: hello'

out=$(ask 'scenario:multiline')
assert_contains 'multi-line replies keep their first line' "$out" 'first line'
assert_contains 'multi-line replies keep their last line' "$out" 'third line'

# Quotes and backslashes must survive jq's encoding rather than corrupting the
# request, which is the whole reason the payload is not built by interpolation.
out=$(ask 'what does "it'\''s \ 100%" mean?')
assert_contains 'quotes and backslashes are escaped' "$out" 'it'\''s'
assert_not_contains 'the request was not malformed' "$(flatten "$out")" 'not valid JSON'

out=$(ask 'scenario:unauthorized')
assert_says '401 is reported as a key problem' "$out" 'Invalid API key'
assert_says '401 includes the server detail' "$out" 'Incorrect API key provided'

out=$(ask 'scenario:server_error')
assert_says '500 is reported' "$out" 'Server error 500'

out=$(ask 'scenario:rate_limit')
assert_contains '429 is retried and then succeeds' "$out" 'recovered after rate limit'

out=$(ask 'scenario:rate_limit_always')
assert_says 'a persistent 429 is reported' "$out" 'Rate limited'

out=$(ask 'scenario:malformed')
assert_says 'truncated JSON is reported' "$out" 'not valid JSON'

out=$(ask 'scenario:empty')
assert_says 'an empty reply is reported' "$out" 'empty reply'
assert_says 'an empty reply explains why' "$out" 'content_filter'

out=$(ask 'scenario:nonsense')
assert_says 'an unexpected status is reported' "$out" 'Unexpected response 400'

# The REPL must survive every one of the above.
out=$(printf 'scenario:server_error\nhello\n/quit\n' | env \
    COLUMNS="$COLS" NO_COLOR=1 DPAD_DATA_DIR="$WORK_DIR/data" \
    DPAD_API_KEY='fixture-value-not-a-secret' DPAD_BASE_URL="$MOCK_URL" \
    "$REPO_ROOT/app/chat.sh" 2>&1)
assert_contains 'the REPL survives a failed request' "$out" 'You said: hello'

# -----------------------------------------------------------------------------
# Request shape
# -----------------------------------------------------------------------------

out=$(DPAD_MODEL='test-model-9' ask 'scenario:echo_payload')
assert_contains 'the configured model is sent' "$out" 'test-model-9'
assert_contains 'a system prompt is sent' "$out" 'system'
assert_contains 'max_tokens is sent' "$out" 'max_tokens'

# -----------------------------------------------------------------------------
# Transport failures
# -----------------------------------------------------------------------------

out=$(printf 'hello\n/quit\n' | env \
    COLUMNS="$COLS" NO_COLOR=1 DPAD_DATA_DIR="$WORK_DIR/data" \
    DPAD_API_KEY='fixture-value-not-a-secret' \
    DPAD_BASE_URL='http://127.0.0.1:1/v1' \
    "$REPO_ROOT/app/chat.sh" 2>&1)
assert_says 'a refused connection is explained' "$out" 'Check WiFi'

out=$(TEST_TIMEOUT=1 ask 'scenario:slow')
assert_says 'a timeout is reported with its limit' "$out" 'Timed out after 1s'

# -----------------------------------------------------------------------------
# Without a key
# -----------------------------------------------------------------------------

out=$(printf 'hello\n/quit\n' | env \
    COLUMNS="$COLS" NO_COLOR=1 DPAD_DATA_DIR="$WORK_DIR/nokey" \
    DPAD_BASE_URL="$MOCK_URL" \
    "$REPO_ROOT/app/chat.sh" 2>&1)
assert_contains 'a missing key is reported at startup' "$out" 'No API key set'
assert_says 'a missing key does not end the session' "$out" 'No API key set. See /help'

# -----------------------------------------------------------------------------
# The key must not leak
# -----------------------------------------------------------------------------

SECRET='canary-value-must-never-be-printed'
out=$(printf 'hello\n/about\n/quit\n' | env \
    COLUMNS="$COLS" NO_COLOR=1 DPAD_DATA_DIR="$WORK_DIR/secret" \
    DPAD_API_KEY="$SECRET" DPAD_BASE_URL="$MOCK_URL" \
    "$REPO_ROOT/app/chat.sh" 2>&1)
assert_not_contains 'the key is never printed in full' "$(strip_ws "$out")" "$SECRET"
assert_contains 'the key is shown redacted' "$out" 'canary'

if grep -q "$SECRET" "$WORK_DIR/secret/dpad-chat.log" 2>/dev/null; then
    fail 'the key is never written to the log'
else
    pass 'the key is never written to the log'
fi

# -----------------------------------------------------------------------------
# Settings file
# -----------------------------------------------------------------------------

mkdir -p "$WORK_DIR/cfg"
cat >"$WORK_DIR/cfg/settings.cfg" <<EOF
# a comment
model = from-file-model
max_tokens = 64
base_url = $MOCK_URL
api_key = fixture-from-file-not-a-secret
bogus_key = ignored
not a setting line
EOF

out=$(printf '/about\n/quit\n' | env \
    COLUMNS="$COLS" NO_COLOR=1 DPAD_DATA_DIR="$WORK_DIR/cfg" \
    "$REPO_ROOT/app/chat.sh" 2>&1)
assert_contains 'settings are read from the file' "$out" 'from-file-model'
assert_contains 'whitespace around values is trimmed' "$out" 'model    from-file-model'
assert_contains 'a key in the file is detected' "$out" 'fixtur'

# A settings file is attacker-controlled input on a removable card: it is parsed
# against a whitelist, never sourced.
mkdir -p "$WORK_DIR/evil"
# The command substitution must reach the file as literal text, which is the
# whole point of the test, so the single quotes are deliberate.
# shellcheck disable=SC2016
printf 'model=x\ninjected=$(touch %s/pwned)\n' "$WORK_DIR/evil" >"$WORK_DIR/evil/settings.cfg"
printf '/quit\n' | env \
    COLUMNS="$COLS" NO_COLOR=1 DPAD_DATA_DIR="$WORK_DIR/evil" \
    DPAD_API_KEY='fixture-value-not-a-secret' DPAD_BASE_URL="$MOCK_URL" \
    "$REPO_ROOT/app/chat.sh" >/dev/null 2>&1
if [ -e "$WORK_DIR/evil/pwned" ]; then
    fail 'the settings file is not executed'
else
    pass 'the settings file is not executed'
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
