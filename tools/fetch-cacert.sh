#!/bin/sh
# Refresh the bundled CA certificates.
#
# Onion OS ships no CA store, which is why its own scripts all call `curl -k`.
# That is tolerable for fetching public release metadata and unacceptable for a
# request carrying an API key, so the app brings its own trust anchors.
#
# The bundle is committed rather than fetched at install time: the device may
# have no working network when it first runs, and a trust store downloaded over
# an unverified connection would defeat the point.
#
#   tools/fetch-cacert.sh            refresh app/res/cacert.pem
#   tools/fetch-cacert.sh --check    verify the committed copy is intact

set -eu

SOURCE_URL='https://curl.se/ca/cacert.pem'
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
BUNDLE="$REPO_ROOT/app/res/cacert.pem"
MANIFEST="$REPO_ROOT/app/res/cacert.sha256"

fail() {
    printf 'fetch-cacert: %s\n' "$*" >&2
    exit 1
}

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        fail 'no sha256sum or shasum available'
    fi
}

check() {
    [ -f "$BUNDLE" ] || fail "missing $BUNDLE"
    [ -f "$MANIFEST" ] || fail "missing $MANIFEST"

    # Only the first line holds the checksum; the rest records provenance.
    expected=$(head -n 1 "$MANIFEST" | cut -d' ' -f1)
    actual=$(checksum "$BUNDLE")

    if [ "$expected" != "$actual" ]; then
        printf 'cacert.pem does not match its recorded checksum\n' >&2
        printf '  expected %s\n  actual   %s\n' "$expected" "$actual" >&2
        exit 1
    fi

    count=$(grep -c 'BEGIN CERTIFICATE' "$BUNDLE" || true)
    printf 'ok: cacert.pem matches its checksum (%s certificates)\n' "$count"
}

fetch() {
    command -v curl >/dev/null 2>&1 || fail 'curl is required'

    tmp="$BUNDLE.tmp"
    printf 'Fetching %s\n' "$SOURCE_URL"

    # Verified against the host's own trust store: this is the one fetch that
    # cannot use the bundle it is about to replace.
    curl -fsS --proto '=https' --tlsv1.2 -o "$tmp" "$SOURCE_URL" ||
        fail 'download failed'

    grep -q 'BEGIN CERTIFICATE' "$tmp" || {
        rm -f "$tmp"
        fail 'downloaded file contains no certificates'
    }

    mv -f "$tmp" "$BUNDLE"

    {
        printf '%s  cacert.pem\n' "$(checksum "$BUNDLE")"
        printf '# source: %s\n' "$SOURCE_URL"
        printf '# fetched: %s\n' "$(date -u '+%Y-%m-%d')"
    } >"$MANIFEST"

    printf 'Wrote %s (%s certificates)\n' "$BUNDLE" \
        "$(grep -c 'BEGIN CERTIFICATE' "$BUNDLE")"
}

case "${1:-}" in
    --check) check ;;
    '') fetch ;;
    *) fail "unknown option: $1" ;;
esac
