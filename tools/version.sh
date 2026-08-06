#!/bin/sh
# Read and bump the application version.
#
# app/lib/common.sh is the single source of truth. Tags and releases are derived
# from it, not the other way round, so a checkout at any commit reports the same
# version the app itself prints in /about.
#
#   tools/version.sh                 print the current version
#   tools/version.sh next patch      print what the next version would be
#   tools/version.sh bump minor      rewrite common.sh with the next version
#
# Bumping is separated from printing so CI can show the result of a label before
# anything is written, and so the rewrite is a single reviewable step.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
VERSION_FILE="$REPO_ROOT/app/lib/common.sh"

fail() {
    printf 'version: %s\n' "$*" >&2
    exit 1
}

current() {
    version=$(sed -n "s/^DPADCHAT_VERSION='\([^']*\)'.*/\1/p" "$VERSION_FILE" | head -n 1)
    [ -n "$version" ] || fail "no DPADCHAT_VERSION found in $VERSION_FILE"
    _validate "$version"
    printf '%s' "$version"
}

# Anything that is not three dot-separated integers would produce a tag that
# does not sort, so it is rejected rather than propagated into a release.
_validate() {
    case "$1" in
        *[!0-9.]* | '') fail "malformed version: $1" ;;
    esac

    saved_ifs=$IFS
    IFS='.'
    # shellcheck disable=SC2086
    set -- $1
    IFS=$saved_ifs

    [ $# -eq 3 ] || fail "version must have three parts, got $#"
    for part in "$@"; do
        [ -n "$part" ] || fail 'version has an empty part'
    done
}

next() {
    version=$(current)

    saved_ifs=$IFS
    IFS='.'
    # shellcheck disable=SC2086
    set -- $version
    IFS=$saved_ifs

    major=$1
    minor=$2
    patch=$3

    case "$BUMP" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            fail "bump must be major, minor or patch; got '$BUMP'"
            ;;
    esac

    printf '%s.%s.%s' "$major" "$minor" "$patch"
}

bump() {
    old=$(current)
    new=$(next)

    tmp="$VERSION_FILE.tmp"
    sed "s/^DPADCHAT_VERSION='[^']*'/DPADCHAT_VERSION='$new'/" \
        "$VERSION_FILE" >"$tmp" || fail 'rewrite failed'

    # Confirm the rewrite before replacing the original: a sed that silently
    # matched nothing would otherwise produce a release tagged with the old
    # version.
    grep -q "^DPADCHAT_VERSION='$new'" "$tmp" || {
        rm -f "$tmp"
        fail 'rewrite did not take effect'
    }

    mv -f "$tmp" "$VERSION_FILE"
    printf '%s -> %s\n' "$old" "$new"
}

case "${1:-current}" in
    current)
        current
        printf '\n'
        ;;
    next)
        [ $# -eq 2 ] || fail 'usage: version.sh next <major|minor|patch>'
        BUMP=$2
        next
        printf '\n'
        ;;
    bump)
        [ $# -eq 2 ] || fail 'usage: version.sh bump <major|minor|patch>'
        BUMP=$2
        bump
        ;;
    *)
        fail "unknown command: $1"
        ;;
esac
