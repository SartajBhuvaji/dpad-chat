#!/bin/sh
# Self-update against the project's GitHub releases.
#
# Splits into two halves that never run at the same time. This file checks for a
# newer release, downloads it and unpacks it into the data directory, all while
# the app is running. apply-update.sh then copies that staged tree over the app
# directory, and runs only from launch.sh before anything else has started.
#
# The split is not tidiness. The shell reads a script incrementally from an open
# file descriptor, so overwriting chat.sh or launch.sh while either is executing
# resumes the interpreter at a byte offset in different content. Staging first
# means the copy happens when nothing from the app directory is running.
#
# Nothing here is ever fatal to the session: a failed update leaves the app
# exactly as it was, and the worst outcome is a message at the prompt.

# UPDATE_* are this module's interface, read by chat.sh after sourcing. Static
# analysis works one file at a time and cannot see those uses.
# shellcheck disable=SC2034

UPDATE_REPO='SartajBhuvaji/dpad-chat'

# Overridable so the tests can point at the mock server instead of GitHub.
UPDATE_API="${DPAD_UPDATE_API:-https://api.github.com}"

# The release carries a .zip for people installing by hand from a desktop and a
# .tar.gz for this path. busybox always has tar and gzip; unzip is an optional
# applet, and finding out it is missing after a download is too late.
UPDATE_ASSET_SUFFIX='.tar.gz'

# Refuse anything larger than this. The app is a few hundred kilobytes, and the
# SD card is the only storage the device has.
UPDATE_MAX_BYTES=8388608

UPDATE_CONNECT_TIMEOUT=15
UPDATE_TIMEOUT=180

# Files that must be present in a staged tree before it is allowed to replace a
# working install. Mirrors REQUIRED in tools/package.py.
UPDATE_REQUIRED='config.json launch.sh chat.sh lib/common.sh res/cacert.pem'

# Results. UPDATE_VERSION is the version offered by the server, which may be the
# one already installed; UPDATE_ERROR is a message worth putting on screen.
UPDATE_VERSION=''
UPDATE_ERROR=''
UPDATE_ASSET_URL=''

UPDATE_APP_DIR=''
UPDATE_STAGE_DIR=''
UPDATE_CACERT=''
UPDATE_WORK=''

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------

# update_init <app-dir> <data-dir> <cacert>
#
# The staging area lives under the data directory, which tools/package.py
# excludes from the archive. That is what makes it safe to unpack an update into
# a directory the update itself will never overwrite.
update_init() {
    UPDATE_APP_DIR="$1"
    UPDATE_STAGE_DIR="$2/update"
    UPDATE_CACERT="$3"
}

update_stage_dir() {
    printf '%s' "$UPDATE_STAGE_DIR"
}

# True when a staged tree is waiting for the next launch to apply it.
update_is_pending() {
    [ -f "$UPDATE_STAGE_DIR/ready" ]
}

# -----------------------------------------------------------------------------
# Versions
# -----------------------------------------------------------------------------

# Tags are vX.Y.Z; the version inside the app is X.Y.Z.
update_version_from_tag() {
    printf '%s' "${1#v}"
}

# Three dot-separated integers, no empty parts. A malformed version would make
# the comparison below meaningless, and offering an update to something that
# cannot be ordered is worse than reporting nothing.
update_version_is_valid() {
    case "$1" in
        '' | *[!0-9.]*) return 1 ;;
    esac

    _v_major="${1%%.*}"
    _v_rest="${1#*.}"
    _v_minor="${_v_rest%%.*}"
    _v_patch="${_v_rest#*.}"

    # "1.2" leaves the patch equal to the minor, and "1.2.3.4" leaves a dot in
    # the patch. Both are rejected here rather than silently compared.
    case "$_v_patch" in
        *.*) return 1 ;;
    esac
    [ "$_v_major.$_v_minor.$_v_patch" = "$1" ] || return 1

    [ -n "$_v_major" ] && [ -n "$_v_minor" ] && [ -n "$_v_patch" ]
}

# update_is_newer <candidate> <installed>
#
# Returns 0 only when the candidate is strictly greater. Equal versions and
# anything unparseable return non-zero, so an update is offered only when the
# ordering is certain.
#
# Each part is compared as a number, not as text. Sorted as text, "10" comes
# before "9", so every release after 0.9.0 would look like a downgrade and the
# app would stop offering updates without ever saying why.
#
# Spelled out one part at a time rather than through a three-state helper: a
# function can only answer with an exit status, and "keep looking" is not one of
# the two things an exit status means.
update_is_newer() {
    update_version_is_valid "$1" || return 1
    update_version_is_valid "$2" || return 1

    _n_new_rest="${1#*.}"
    _n_old_rest="${2#*.}"

    if [ "${1%%.*}" -ne "${2%%.*}" ]; then
        if [ "${1%%.*}" -gt "${2%%.*}" ]; then
            return 0
        fi
        return 1
    fi

    if [ "${_n_new_rest%%.*}" -ne "${_n_old_rest%%.*}" ]; then
        if [ "${_n_new_rest%%.*}" -gt "${_n_old_rest%%.*}" ]; then
            return 0
        fi
        return 1
    fi

    if [ "${_n_new_rest#*.}" -gt "${_n_old_rest#*.}" ]; then
        return 0
    fi

    # Equal, or the patch is lower. Neither is an update.
    return 1
}

# -----------------------------------------------------------------------------
# Checking
# -----------------------------------------------------------------------------

# update_check
#
# On success UPDATE_VERSION holds the latest published version and
# UPDATE_ASSET_URL the archive to fetch. On failure UPDATE_ERROR explains why.
update_check() {
    UPDATE_VERSION=''
    UPDATE_ASSET_URL=''
    UPDATE_ERROR=''

    _update_workdir || return 1

    if ! _update_fetch_release; then
        _update_cleanup
        return 1
    fi

    tag=$(jq -r '.tag_name // empty' "$UPDATE_WORK/release.json" 2>/dev/null || :)
    if [ -z "$tag" ]; then
        UPDATE_ERROR='The release listing had no version in it.'
        _update_cleanup
        return 1
    fi

    UPDATE_VERSION=$(update_version_from_tag "$tag")
    if ! update_version_is_valid "$UPDATE_VERSION"; then
        UPDATE_ERROR="The latest release is tagged '$tag', which is not a version."
        UPDATE_VERSION=''
        _update_cleanup
        return 1
    fi

    UPDATE_ASSET_URL=$(jq -r --arg suffix "$UPDATE_ASSET_SUFFIX" \
        'first(.assets[]? | select(.name | endswith($suffix))) | .url // empty' \
        "$UPDATE_WORK/release.json" 2>/dev/null || :)

    if [ -z "$UPDATE_ASSET_URL" ]; then
        UPDATE_ERROR="Release $tag has no $UPDATE_ASSET_SUFFIX to install. Update by hand from the releases page."
        _update_cleanup
        return 1
    fi

    _update_cleanup
    return 0
}

_update_fetch_release() {
    url="$UPDATE_API/repos/$UPDATE_REPO/releases/latest"
    log_info "GET $url"

    _update_write_curl_config 'application/vnd.github+json'
    cat >>"$UPDATE_WORK/curl.cfg" <<EOF
url = "$url"
output = "$UPDATE_WORK/release.json"
write-out = "%{http_code}"
EOF

    status=$(curl --config "$UPDATE_WORK/curl.cfg" 2>"$UPDATE_WORK/curl.err")
    curl_status=$?

    if [ "$curl_status" -ne 0 ]; then
        UPDATE_ERROR=$(_update_transport_error "$curl_status")
        log_error "update check: curl exit $curl_status"
        return 1
    fi

    log_info "update check: HTTP $status"

    case "$status" in
        200) return 0 ;;
        401 | 403)
            UPDATE_ERROR='GitHub refused the request. If github_token is set in settings.cfg, check that it is still valid.'
            ;;
        404)
            # The public case and the private case are indistinguishable from
            # here: GitHub answers 404 for a repository the caller cannot see,
            # so the message has to cover both.
            UPDATE_ERROR="No releases found for $UPDATE_REPO. If the repository is private, add github_token to settings.cfg."
            ;;
        *)
            UPDATE_ERROR="GitHub answered $status."
            ;;
    esac

    return 1
}

# -----------------------------------------------------------------------------
# Downloading
# -----------------------------------------------------------------------------

# update_download_and_stage <version>
#
# Fetches the archive named by the last update_check, unpacks it into the
# staging area and marks it ready. The app directory is not touched.
update_download_and_stage() {
    UPDATE_ERROR=''

    if [ -z "$UPDATE_ASSET_URL" ]; then
        UPDATE_ERROR='Nothing to download; check for updates first.'
        return 1
    fi

    if ! command -v tar >/dev/null 2>&1; then
        UPDATE_ERROR='tar is missing, so the archive cannot be unpacked.'
        return 1
    fi

    _update_workdir || return 1

    if ! _update_fetch_asset; then
        _update_cleanup
        return 1
    fi

    if ! _update_unpack "$UPDATE_WORK/update.tar.gz"; then
        _update_cleanup
        return 1
    fi

    if ! _update_mark_ready "$1"; then
        _update_cleanup
        return 1
    fi

    _update_cleanup
    return 0
}

_update_fetch_asset() {
    log_info "GET $UPDATE_ASSET_URL"

    # The asset API URL is used rather than browser_download_url because it is
    # the one form that works for a private repository as well as a public one.
    # It answers with a redirect to a signed CDN URL; curl drops the
    # Authorization header when a redirect crosses hosts, which is what keeps
    # the token from reaching the CDN.
    _update_write_curl_config 'application/octet-stream'
    cat >>"$UPDATE_WORK/curl.cfg" <<EOF
url = "$UPDATE_ASSET_URL"
output = "$UPDATE_WORK/update.tar.gz"
write-out = "%{http_code}"
location
max-filesize = $UPDATE_MAX_BYTES
EOF

    status=$(curl --config "$UPDATE_WORK/curl.cfg" 2>"$UPDATE_WORK/curl.err")
    curl_status=$?

    if [ "$curl_status" -ne 0 ]; then
        UPDATE_ERROR=$(_update_transport_error "$curl_status")
        log_error "update download: curl exit $curl_status"
        return 1
    fi

    if [ "$status" != '200' ]; then
        UPDATE_ERROR="The download failed with $status."
        return 1
    fi

    if [ ! -s "$UPDATE_WORK/update.tar.gz" ]; then
        UPDATE_ERROR='The download was empty.'
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Staging
# -----------------------------------------------------------------------------

_update_unpack() {
    rm -rf "$UPDATE_STAGE_DIR" 2>/dev/null || :
    if ! mkdir -p "$UPDATE_STAGE_DIR/tree"; then
        UPDATE_ERROR="Could not write to $UPDATE_STAGE_DIR."
        return 1
    fi

    if ! _update_entries_are_safe "$1"; then
        return 1
    fi

    if ! tar -xzf "$1" -C "$UPDATE_STAGE_DIR/tree" 2>>"$UPDATE_STAGE_DIR/unpack.err"; then
        UPDATE_ERROR='The archive could not be unpacked.'
        return 1
    fi

    if ! _update_tree_is_complete "$UPDATE_STAGE_DIR/tree/App/DPadChat"; then
        return 1
    fi

    return 0
}

# An archive is remote input, and tar will happily write wherever its entries
# point. Only names under the expected prefix are accepted, which rules out
# absolute paths and traversal without relying on the tar build being the
# hardened one.
#
# The prefix test is the one that does the work, not the `..` test below it.
# busybox `tar -t` reports entries already normalised, so a name written as
# `App/DPadChat/../../../etc/passwd` is listed as `etc/passwd` and never
# contains `..` by the time it is read here — it fails the prefix instead. GNU
# tar reports it verbatim and fails the second test. Both refuse; which message
# comes out depends on the tar, which is why the test asserts on neither.
_update_entries_are_safe() {
    if ! tar -tzf "$1" >"$UPDATE_STAGE_DIR/entries.txt" 2>/dev/null; then
        UPDATE_ERROR='The archive could not be read.'
        return 1
    fi

    if [ ! -s "$UPDATE_STAGE_DIR/entries.txt" ]; then
        UPDATE_ERROR='The archive was empty.'
        return 1
    fi

    while IFS= read -r entry; do
        case "$entry" in
            'App/DPadChat/'*) ;;
            *)
                UPDATE_ERROR="The archive contains an unexpected path: $entry"
                log_error "update: rejected archive entry '$entry'"
                return 1
                ;;
        esac

        case "$entry" in
            *'..'*)
                UPDATE_ERROR="The archive contains a path that points outside the app: $entry"
                log_error "update: rejected traversal entry '$entry'"
                return 1
                ;;
        esac
    done <"$UPDATE_STAGE_DIR/entries.txt"

    return 0
}

# A tree missing any of these would replace a working install with one that
# cannot start, on a device whose only recovery is pulling the card out.
_update_tree_is_complete() {
    for required in $UPDATE_REQUIRED; do
        if [ ! -f "$1/$required" ]; then
            UPDATE_ERROR="The download is incomplete ($required is missing)."
            log_error "update: staged tree missing $required"
            return 1
        fi
    done
    return 0
}

# The applier is copied out of the staged tree, not out of the running install:
# the new release is the one that knows its own layout, and it is the copy that
# was reviewed alongside the files it will be moving into place.
#
# It has to live outside the app directory it rewrites, which is why it runs
# from here rather than from where it will shortly be installed.
_update_mark_ready() {
    staged="$UPDATE_STAGE_DIR/tree/App/DPadChat/apply-update.sh"

    if [ ! -f "$staged" ]; then
        UPDATE_ERROR='The download has no installer in it.'
        return 1
    fi

    if ! cp "$staged" "$UPDATE_STAGE_DIR/apply.sh"; then
        UPDATE_ERROR='Could not stage the installer.'
        return 1
    fi
    chmod 755 "$UPDATE_STAGE_DIR/apply.sh" 2>/dev/null || :

    # Written last, and by a rename, so a launch that lands mid-stage sees no
    # marker rather than a half-written one.
    printf '%s\n' "$1" >"$UPDATE_STAGE_DIR/ready.tmp" || {
        UPDATE_ERROR='Could not record the staged update.'
        return 1
    }
    mv -f "$UPDATE_STAGE_DIR/ready.tmp" "$UPDATE_STAGE_DIR/ready" || {
        UPDATE_ERROR='Could not record the staged update.'
        return 1
    }

    log_info "update $1 staged in $UPDATE_STAGE_DIR"
    return 0
}

# -----------------------------------------------------------------------------
# Transport
# -----------------------------------------------------------------------------

_update_workdir() {
    UPDATE_WORK=$(mktemp -d 2>/dev/null || mktemp -d -t dpad) || {
        UPDATE_ERROR='Could not create a temporary directory.'
        return 1
    }
    # The config file below can carry a GitHub token.
    chmod 700 "$UPDATE_WORK" 2>/dev/null || :
}

_update_cleanup() {
    if [ -n "${UPDATE_WORK:-}" ]; then
        rm -rf "$UPDATE_WORK"
    fi
    UPDATE_WORK=''
}

# The token goes in a config file rather than on the command line, where it
# would be readable by any other process through /proc or `ps`. The OpenAI key
# is never sent here; these are different services and only one of them is
# being asked for a file.
_update_write_curl_config() {
    umask 077
    cat >"$UPDATE_WORK/curl.cfg" <<EOF
header = "Accept: $1"
header = "X-GitHub-Api-Version: 2022-11-28"
user-agent = "dpad-chat/${DPADCHAT_VERSION:-dev}"
request = "GET"
silent
show-error
connect-timeout = $UPDATE_CONNECT_TIMEOUT
max-time = $UPDATE_TIMEOUT
EOF

    if [ -n "${CFG_GITHUB_TOKEN:-}" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$CFG_GITHUB_TOKEN" \
            >>"$UPDATE_WORK/curl.cfg"
    fi

    _update_append_tls_config

    # Both call sites invoke this as a bare statement, where under `set -e` a
    # non-zero status would take the whole session down. The config is checked
    # by curl failing on it, not by this return value.
    return 0
}

# Same rule as the chat endpoint: verified against the bundled CA or not at all.
# There is no insecure fallback, because the thing being fetched is code that
# will replace the app.
_update_append_tls_config() {
    case "$UPDATE_API" in
        https://*) ;;
        *) return 0 ;;
    esac

    cat >>"$UPDATE_WORK/curl.cfg" <<EOF
cacert = "$UPDATE_CACERT"
proto = "=https"
proto-redir = "=https"
tlsv1.2
EOF
}

_update_transport_error() {
    case "$1" in
        6) printf 'Could not resolve github.com. Check WiFi and DNS.' ;;
        7) printf 'Could not connect to GitHub. Check WiFi.' ;;
        28) printf 'GitHub timed out after %ss.' "$UPDATE_TIMEOUT" ;;
        35 | 60) printf 'TLS failed. Check the system clock and CA bundle.' ;;
        63) printf 'The download was larger than %s bytes and was refused.' "$UPDATE_MAX_BYTES" ;;
        *) printf 'Network error (curl %s).' "$1" ;;
    esac
}
