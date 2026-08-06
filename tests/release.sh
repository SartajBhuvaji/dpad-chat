#!/bin/sh
# Versioning and packaging tests.
#
# The release workflow cannot be run locally, so the pieces it calls are tested
# directly instead. A bad bump or a package missing the CA bundle would only
# surface as a broken published release.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

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

# A sandbox copy, so bumping never rewrites the checkout.
sandbox() {
    rm -rf "$WORK_DIR/repo"
    mkdir -p "$WORK_DIR/repo/app/lib" "$WORK_DIR/repo/tools"
    printf "DPADCHAT_VERSION='%s'\nother='untouched'\n" "$1" \
        >"$WORK_DIR/repo/app/lib/common.sh"
    cp "$REPO_ROOT/tools/version.sh" "$WORK_DIR/repo/tools/"
}

# -----------------------------------------------------------------------------

printf 'Running release tests\n'

# -----------------------------------------------------------------------------
# Version arithmetic
# -----------------------------------------------------------------------------

sandbox '1.4.9'
assert_eq 'the current version is read' \
    "$(sh "$WORK_DIR/repo/tools/version.sh")" '1.4.9'
assert_eq 'patch increments the last part' \
    "$(sh "$WORK_DIR/repo/tools/version.sh" next patch)" '1.4.10'
assert_eq 'minor resets patch' \
    "$(sh "$WORK_DIR/repo/tools/version.sh" next minor)" '1.5.0'
assert_eq 'major resets minor and patch' \
    "$(sh "$WORK_DIR/repo/tools/version.sh" next major)" '2.0.0'

# Ten must follow nine rather than sorting before two.
sandbox '0.9.0'
assert_eq 'minor crosses ten without wrapping' \
    "$(sh "$WORK_DIR/repo/tools/version.sh" next minor)" '0.10.0'

# -----------------------------------------------------------------------------
# Rewriting
# -----------------------------------------------------------------------------

sandbox '0.2.3'
sh "$WORK_DIR/repo/tools/version.sh" bump minor >/dev/null
assert_eq 'bump rewrites the version file' \
    "$(sh "$WORK_DIR/repo/tools/version.sh")" '0.3.0'
assert_eq 'bump leaves the rest of the file alone' \
    "$(grep -c "other='untouched'" "$WORK_DIR/repo/app/lib/common.sh")" '1'

# -----------------------------------------------------------------------------
# Bad input
# -----------------------------------------------------------------------------

sandbox '1.0.0'
if sh "$WORK_DIR/repo/tools/version.sh" next sideways >/dev/null 2>&1; then
    fail 'an unknown bump kind is rejected'
else
    pass 'an unknown bump kind is rejected'
fi

# A version that is not three integers would produce a tag that does not sort.
sandbox '1.0'
if sh "$WORK_DIR/repo/tools/version.sh" >/dev/null 2>&1; then
    fail 'a two-part version is rejected'
else
    pass 'a two-part version is rejected'
fi

sandbox '1.0.0-beta'
if sh "$WORK_DIR/repo/tools/version.sh" >/dev/null 2>&1; then
    fail 'a non-numeric version is rejected'
else
    pass 'a non-numeric version is rejected'
fi

# -----------------------------------------------------------------------------
# The archive
# -----------------------------------------------------------------------------

python3 "$REPO_ROOT/tools/package.py" --output-dir "$WORK_DIR/dist" >/dev/null
VERSION=$(sh "$REPO_ROOT/tools/version.sh")
ARCHIVE="$WORK_DIR/dist/DPadChat-v$VERSION.zip"

if [ -f "$ARCHIVE" ]; then
    pass 'the archive is named for the current version'
else
    fail 'the archive is named for the current version' "no $ARCHIVE"
fi

listing=$(python3 -c "
import sys, zipfile
print('\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))
" "$ARCHIVE")

for required in \
    'App/DPadChat/config.json' \
    'App/DPadChat/launch.sh' \
    'App/DPadChat/chat.sh' \
    'App/DPadChat/res/cacert.pem' \
    'App/DPadChat/res/icon.png'; do
    case "$listing" in
        *"$required"*) pass "the archive contains $required" ;;
        *) fail "the archive contains $required" ;;
    esac
done

# Unpacking must land on /mnt/SDCARD directly; a bare payload would scatter
# files across the card's root.
case "$listing" in
    App/DPadChat/*) pass 'the archive unpacks to App/DPadChat' ;;
    *) fail 'the archive unpacks to App/DPadChat' ;;
esac

# The transcript and the API key must never be published.
case "$listing" in
    *App/DPadChat/data/*) fail 'runtime data is excluded from the archive' ;;
    *) pass 'runtime data is excluded from the archive' ;;
esac

# Onion runs launch.sh directly, so it has to arrive executable regardless of
# what the checkout's filesystem recorded.
modes=$(python3 -c "
import sys, zipfile
for i in zipfile.ZipFile(sys.argv[1]).infolist():
    if i.filename.endswith(('launch.sh', 'chat.sh')):
        print(oct(i.external_attr >> 16)[2:])
" "$ARCHIVE")

if [ "$(printf '%s\n' "$modes" | sort -u)" = '755' ]; then
    pass 'entry points are executable in the archive'
else
    fail 'entry points are executable in the archive' "modes: $(printf '%s' "$modes" | tr '\n' ' ')"
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
