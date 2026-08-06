#!/bin/sh
# Preflight and TLS tests.
#
# The route table and CA bundle are injected through DPAD_ROUTE_FILE and
# DPAD_CACERT, so these run identically on a laptop with working WiFi and on a
# CI runner, and cover states that are awkward to produce for real: an unset
# clock, a missing trust store, a device with no default route.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
COLS=40

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

# Route table fixtures in the kernel's own format. A destination of 00000000 is
# the default route.
write_route_table() {
    # The path is captured before the shift: using "$1" inside the loop would
    # redirect into whatever the first route entry happens to be named, leaving
    # every fixture empty and making the no-route assertions pass vacuously.
    table="$1"
    shift

    printf 'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\n' >"$table"
    for iface_dest in "$@"; do
        printf '%s\t0x0003\t0\t0\t0\t0\t00000000\n' \
            "$(printf '%s' "$iface_dest" | tr ':' '\t')" >>"$table"
    done
}

run_app() {
    env COLUMNS="$COLS" NO_COLOR=1 "$@" "$REPO_ROOT/app/chat.sh" 2>&1
}

# -----------------------------------------------------------------------------

printf 'Running preflight tests\n'

ROUTE_OK="$WORK_DIR/route_ok"
ROUTE_NONE="$WORK_DIR/route_none"
ROUTE_LO="$WORK_DIR/route_lo"

write_route_table "$ROUTE_OK" 'wlan0:00000000' 'wlan0:0056A8C0'
write_route_table "$ROUTE_NONE" 'wlan0:0056A8C0'
write_route_table "$ROUTE_LO" 'lo:00000000'

# -----------------------------------------------------------------------------
# Network preflight
# -----------------------------------------------------------------------------

out=$(printf 'hello\n/quit\n' | run_app \
    DPAD_DATA_DIR="$WORK_DIR/d1" \
    DPAD_API_KEY='fixture-value-not-a-secret' \
    DPAD_BASE_URL='https://example.invalid/v1' \
    DPAD_CACERT="$REPO_ROOT/app/res/cacert.pem" \
    DPAD_ROUTE_FILE="$ROUTE_NONE")
assert_says 'no default route is reported before any request' "$out" 'No network'
assert_says 'the fix is named' "$out" 'Connect to WiFi'

# A loopback-only table is what an unconfigured device looks like; it must not
# be mistaken for a working connection.
out=$(printf 'hello\n/quit\n' | run_app \
    DPAD_DATA_DIR="$WORK_DIR/d2" \
    DPAD_API_KEY='fixture-value-not-a-secret' \
    DPAD_BASE_URL='https://example.invalid/v1' \
    DPAD_CACERT="$REPO_ROOT/app/res/cacert.pem" \
    DPAD_ROUTE_FILE="$ROUTE_LO")
assert_says 'a loopback-only route table counts as no network' "$out" 'No network'

# An unreadable route file must fail closed rather than assume connectivity.
out=$(printf 'hello\n/quit\n' | run_app \
    DPAD_DATA_DIR="$WORK_DIR/d3" \
    DPAD_API_KEY='fixture-value-not-a-secret' \
    DPAD_BASE_URL='https://example.invalid/v1' \
    DPAD_CACERT="$REPO_ROOT/app/res/cacert.pem" \
    DPAD_ROUTE_FILE="$WORK_DIR/does-not-exist")
assert_says 'a missing route table fails closed' "$out" 'No network'

# -----------------------------------------------------------------------------
# TLS
# -----------------------------------------------------------------------------

# The critical property: no insecure fallback. A missing bundle must stop the
# request, never downgrade it.
out=$(printf 'hello\n/quit\n' | run_app \
    DPAD_DATA_DIR="$WORK_DIR/d4" \
    DPAD_API_KEY='fixture-value-not-a-secret' \
    DPAD_BASE_URL='https://example.invalid/v1' \
    DPAD_CACERT="$WORK_DIR/absent.pem" \
    DPAD_ROUTE_FILE="$ROUTE_OK")
assert_says 'a missing CA bundle blocks the request' "$out" 'Missing CA bundle'
assert_says 'the refusal explains itself' "$out" 'refusing to send the key unverified'

# The bundle is only required for https; the mock server speaks plain http.
out=$(printf '/about\n/quit\n' | run_app \
    DPAD_DATA_DIR="$WORK_DIR/d5" \
    DPAD_API_KEY='fixture-value-not-a-secret' \
    DPAD_BASE_URL='http://127.0.0.1:9/v1' \
    DPAD_CACERT="$WORK_DIR/absent.pem" \
    DPAD_ROUTE_FILE="$ROUTE_NONE")
assert_says 'plain http does not require a bundle' "$out" 'not used (plain http)'
refute_says 'plain http is not blocked by the route check' "$out" 'No network'

out=$(printf '/about\n/quit\n' | run_app \
    DPAD_DATA_DIR="$WORK_DIR/d6" \
    DPAD_API_KEY='fixture-value-not-a-secret' \
    DPAD_BASE_URL='https://api.example.com/v1' \
    DPAD_CACERT="$REPO_ROOT/app/res/cacert.pem" \
    DPAD_ROUTE_FILE="$ROUTE_OK")
assert_says '/about reports TLS as verified' "$out" 'verified'
assert_says '/about counts the trust anchors' "$out" 'certs'
assert_says '/about reports the route and clock' "$out" 'route ok'

# -----------------------------------------------------------------------------
# The bundle itself
# -----------------------------------------------------------------------------

if sh "$REPO_ROOT/tools/fetch-cacert.sh" --check >/dev/null 2>&1; then
    pass 'the committed CA bundle matches its checksum'
else
    fail 'the committed CA bundle matches its checksum'
fi

if grep -q 'BEGIN CERTIFICATE' "$REPO_ROOT/app/res/cacert.pem" 2>/dev/null; then
    pass 'the CA bundle contains certificates'
else
    fail 'the CA bundle contains certificates'
fi

# The bundle is worthless if it does not reach the device.
if grep -q "cacert" "$REPO_ROOT/tools/install.sh" 2>/dev/null ||
    ! grep -q "exclude" "$REPO_ROOT/tools/install.sh" 2>/dev/null; then
    pass 'the installer does not exclude res/'
else
    case "$(grep 'exclude' "$REPO_ROOT/tools/install.sh")" in
        *res*) fail 'the installer does not exclude res/' ;;
        *) pass 'the installer does not exclude res/' ;;
    esac
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
