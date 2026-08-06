#!/bin/sh
# Self-update tests.
#
# Two halves, matching the two halves of the feature. The version arithmetic and
# the archive checks are exercised directly, because they are what decides
# whether an install gets replaced. The download runs against the mock server
# rather than fixtures on disk: a directory of pre-unpacked files would test the
# parsing and skip the part that actually breaks.
#
# apply-update.sh is run for real against a throwaway app directory. It is the
# one script here that can leave a device unable to start, so it is not enough
# to know that it parses.

# Resolve sourced files relative to this script. Must precede the first command
# to apply file-wide.
# shellcheck source-path=SCRIPTDIR

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

TESTS_RUN=0
TESTS_FAILED=0

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
MOCK_PID=''

cleanup() {
    [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null || :
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

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

assert_says() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "expected to find '$3' in: $2" ;;
    esac
}

refute_says() {
    case "$2" in
        *"$3"*) fail "$1" "did not expect '$3' in: $2" ;;
        *) pass "$1" ;;
    esac
}

# newer <candidate> <installed> -> the word the assertions read
newer() {
    if update_is_newer "$1" "$2"; then
        printf 'newer'
    else
        printf 'not-newer'
    fi
}

valid() {
    if update_version_is_valid "$1"; then
        printf 'valid'
    else
        printf 'invalid'
    fi
}

# -----------------------------------------------------------------------------

printf 'Running update tests\n'

NO_COLOR=1
export NO_COLOR

# shellcheck source=../app/lib/common.sh
. "$REPO_ROOT/app/lib/common.sh"
# shellcheck source=../app/lib/update.sh
. "$REPO_ROOT/app/lib/update.sh"

# -----------------------------------------------------------------------------
# Version arithmetic
# -----------------------------------------------------------------------------

assert_eq 'a tag becomes a version' "$(update_version_from_tag 'v1.2.3')" '1.2.3'
assert_eq 'a tag without a v is left alone' "$(update_version_from_tag '1.2.3')" '1.2.3'

assert_eq 'a three-part version is valid' "$(valid '1.2.3')" 'valid'
assert_eq 'zeroes are valid' "$(valid '0.0.0')" 'valid'
assert_eq 'a two-part version is rejected' "$(valid '1.2')" 'invalid'
assert_eq 'a four-part version is rejected' "$(valid '1.2.3.4')" 'invalid'
assert_eq 'an empty part is rejected' "$(valid '1..3')" 'invalid'
assert_eq 'a trailing dot is rejected' "$(valid '1.2.')" 'invalid'
assert_eq 'a prerelease suffix is rejected' "$(valid '1.2.3-rc1')" 'invalid'
assert_eq 'a stray v is rejected' "$(valid 'v1.2.3')" 'invalid'
assert_eq 'empty is rejected' "$(valid '')" 'invalid'

assert_eq 'a higher patch is newer' "$(newer '1.2.4' '1.2.3')" 'newer'
assert_eq 'a higher minor is newer' "$(newer '1.3.0' '1.2.9')" 'newer'
assert_eq 'a higher major is newer' "$(newer '2.0.0' '1.9.9')" 'newer'
assert_eq 'the same version is not newer' "$(newer '1.2.3' '1.2.3')" 'not-newer'
assert_eq 'a lower patch is not newer' "$(newer '1.2.2' '1.2.3')" 'not-newer'
assert_eq 'a lower major outranks a higher minor' "$(newer '1.9.9' '2.0.0')" 'not-newer'

# The comparison has to be numeric. Sorted as text, ten comes before two, and
# every release after 0.9.0 would look like a downgrade.
assert_eq 'ten is newer than nine' "$(newer '0.10.0' '0.9.0')" 'newer'
assert_eq 'nine is not newer than ten' "$(newer '0.9.0' '0.10.0')" 'not-newer'
assert_eq 'ten is newer than two at the patch' "$(newer '1.0.10' '1.0.2')" 'newer'

# An unparseable version can only be ordered by guessing, and guessing here
# means offering to overwrite the app with something unknown.
assert_eq 'an invalid candidate is never newer' "$(newer 'nightly' '1.2.3')" 'not-newer'
assert_eq 'an invalid installed version is never older' "$(newer '9.9.9' 'dev')" 'not-newer'

# -----------------------------------------------------------------------------
# The mock server
# -----------------------------------------------------------------------------

python3 "$REPO_ROOT/tools/mockapi.py" --host 127.0.0.1 --port 0 \
    --port-file "$WORK_DIR/port" >"$WORK_DIR/mock.log" 2>&1 &
MOCK_PID=$!

waited=0
while [ ! -s "$WORK_DIR/port" ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 100 ]; then
        printf 'update tests: the mock server never started\n' >&2
        exit 1
    fi
    sleep 0.1 2>/dev/null || sleep 1
done
PORT=$(cat "$WORK_DIR/port")

# check <scenario> — point the updater at one scenario and run a full check.
check() {
    UPDATE_API="http://127.0.0.1:$PORT/updates/$1"
    update_init "$WORK_DIR/app" "$WORK_DIR/data" "$REPO_ROOT/app/res/cacert.pem"
    if update_check; then
        printf 'ok'
    else
        printf 'failed'
    fi
}

# -----------------------------------------------------------------------------
# Checking
# -----------------------------------------------------------------------------

assert_eq 'a published release is found' "$(check newer)" 'ok'
check newer >/dev/null
assert_eq 'the published version is read' "$UPDATE_VERSION" '99.0.0'
assert_says 'the tarball is the asset chosen' "$UPDATE_ASSET_URL" 'DPadChat.tar.gz'
refute_says 'the zip is not chosen' "$UPDATE_ASSET_URL" 'DPadChat.zip'

assert_eq 'a repository with no releases is a failure' "$(check none)" 'failed'
check none >/dev/null
assert_says 'a missing repository suggests a token' "$UPDATE_ERROR" 'github_token'

assert_eq 'rejected credentials are a failure' "$(check forbidden)" 'failed'
check forbidden >/dev/null
assert_says 'rejected credentials name the setting' "$UPDATE_ERROR" 'github_token'

assert_eq 'a tag that is not a version is a failure' "$(check unversioned)" 'failed'
check unversioned >/dev/null
assert_says 'an unversioned tag is quoted back' "$UPDATE_ERROR" 'nightly'
assert_eq 'an unversioned tag offers nothing' "$UPDATE_VERSION" ''

assert_eq 'a release with no tarball is a failure' "$(check no_asset)" 'failed'

# An older published release still checks out; refusing it is the comparison's
# job, not the fetch's.
assert_eq 'an older release is reported, not rejected' "$(check older)" 'ok'
check older >/dev/null
assert_eq 'an older release is not offered as an update' \
    "$(newer "$UPDATE_VERSION" '1.0.0')" 'not-newer'

# -----------------------------------------------------------------------------
# Downloading and staging
# -----------------------------------------------------------------------------

stage() {
    rm -rf "$WORK_DIR/data"
    mkdir -p "$WORK_DIR/data"
    check "$1" >/dev/null
    if update_download_and_stage '99.0.0'; then
        printf 'ok'
    else
        printf 'failed'
    fi
}

assert_eq 'a good release stages' "$(stage newer)" 'ok'
stage newer >/dev/null

if [ -f "$WORK_DIR/data/update/ready" ]; then
    pass 'staging leaves a marker for the next launch'
else
    fail 'staging leaves a marker for the next launch' 'ready is missing'
fi
assert_eq 'the marker records the version' "$(cat "$WORK_DIR/data/update/ready")" '99.0.0'

if [ -x "$WORK_DIR/data/update/apply.sh" ]; then
    pass 'the installer is staged and executable'
else
    fail 'the installer is staged and executable' 'apply.sh is missing or not executable'
fi

if [ -f "$WORK_DIR/data/update/tree/App/DPadChat/chat.sh" ]; then
    pass 'the new tree is unpacked'
else
    fail 'the new tree is unpacked' 'chat.sh is missing from the staged tree'
fi

update_init "$WORK_DIR/app" "$WORK_DIR/data" "$REPO_ROOT/app/res/cacert.pem"
if update_is_pending; then
    pass 'a staged update is reported as pending'
else
    fail 'a staged update is reported as pending'
fi

# A tarball whose entries point outside the tree must be refused before it is
# unpacked, not cleaned up afterwards.
assert_eq 'an archive that escapes its prefix is refused' "$(stage traversal)" 'failed'
stage traversal >/dev/null
assert_says 'the refusal explains what was wrong' "$UPDATE_ERROR" 'outside the app'
if [ -f "$WORK_DIR/data/update/ready" ]; then
    fail 'a refused archive stages nothing' 'ready was written anyway'
else
    pass 'a refused archive stages nothing'
fi

assert_eq 'an archive that will not unpack is refused' "$(stage corrupt)" 'failed'

# A tree missing a file the app sources would replace a working install with
# one that cannot start, on a device whose only recovery is pulling the card.
assert_eq 'an incomplete tree is refused' "$(stage incomplete)" 'failed'
stage incomplete >/dev/null
assert_says 'the refusal names the missing file' "$UPDATE_ERROR" 'lib/common.sh'
if [ -f "$WORK_DIR/data/update/ready" ]; then
    fail 'an incomplete tree stages nothing' 'ready was written anyway'
else
    pass 'an incomplete tree stages nothing'
fi

# -----------------------------------------------------------------------------
# Applying
# -----------------------------------------------------------------------------

# A throwaway install: an old app directory with state in it, and a staged tree
# holding the new one.
build_install() {
    rm -rf "$WORK_DIR/install"
    mkdir -p "$WORK_DIR/install/app/lib" "$WORK_DIR/install/app/res" \
        "$WORK_DIR/install/app/data/update/tree/App/DPadChat/lib" \
        "$WORK_DIR/install/app/data/update/tree/App/DPadChat/res"

    old="$WORK_DIR/install/app"
    new="$old/data/update/tree/App/DPadChat"

    # The launchers announce themselves, because the installer ends by exec'ing
    # one of them and which one it reached is the whole result: the new one
    # means the update landed, the old one means it was declined.
    printf '#!/bin/sh\nprintf "handed off to old\\n"\n' >"$old/launch.sh"
    chmod 755 "$old/launch.sh"

    printf '#!/bin/sh\n# old\n' >"$old/chat.sh"
    printf '{"old": true}\n' >"$old/config.json"
    printf "DPADCHAT_VERSION='1.0.0'\n" >"$old/lib/common.sh"
    printf 'old bundle\n' >"$old/res/cacert.pem"
    printf 'the conversation\n' >"$old/data/history.json"
    printf 'api_key=secret\n' >"$old/data/settings.cfg"

    printf '#!/bin/sh\nprintf "handed off to new\\n"\n' >"$new/launch.sh"
    for file in chat.sh apply-update.sh; do
        printf '#!/bin/sh\n# new\n' >"$new/$file"
    done
    printf '{"new": true}\n' >"$new/config.json"
    printf "DPADCHAT_VERSION='2.0.0'\n" >"$new/lib/common.sh"
    printf 'new bundle\n' >"$new/res/cacert.pem"

    cp "$REPO_ROOT/app/apply-update.sh" "$old/data/update/apply.sh"
    chmod 755 "$old/data/update/apply.sh"
    printf '2.0.0\n' >"$old/data/update/ready"
}

# The staged copy, run exactly as launch.sh would run it. Nothing is stubbed:
# the launchers it hands off to are the throwaway ones written above, so the
# real exec at the end of the script is part of what is being tested.
apply() {
    sh "$WORK_DIR/install/app/data/update/apply.sh" "$WORK_DIR/install/app" \
        "$WORK_DIR/install/app/data/update" 2>&1
}

build_install
out=$(apply)

assert_says 'applying hands off to the new launcher' "$out" 'handed off to new'
assert_eq 'the new app is in place' \
    "$(cat "$WORK_DIR/install/app/lib/common.sh")" "DPADCHAT_VERSION='2.0.0'"
assert_eq 'files at the top level are replaced' \
    "$(cat "$WORK_DIR/install/app/config.json")" '{"new": true}'
assert_eq 'files under res are replaced' \
    "$(cat "$WORK_DIR/install/app/res/cacert.pem")" 'new bundle'

# The whole point of unpacking beside the app rather than over it.
assert_eq 'the conversation survives an update' \
    "$(cat "$WORK_DIR/install/app/data/history.json")" 'the conversation'
assert_eq 'the settings survive an update' \
    "$(cat "$WORK_DIR/install/app/data/settings.cfg")" 'api_key=secret'

if [ -x "$WORK_DIR/install/app/chat.sh" ]; then
    pass 'the installed app is executable'
else
    fail 'the installed app is executable' 'chat.sh has no executable bit'
fi

if [ -f "$WORK_DIR/install/app/data/update/ready" ]; then
    fail 'the marker is consumed' 'ready is still there and would apply again'
else
    pass 'the marker is consumed'
fi

if [ -d "$WORK_DIR/install/app/data/update/tree" ]; then
    fail 'a finished update cleans up after itself' 'the staged tree is still there'
else
    pass 'a finished update cleans up after itself'
fi

# An incomplete tree is the case where applying would brick the install, so the
# installer has to leave it alone and hand back to the old app.
build_install
rm -f "$WORK_DIR/install/app/data/update/tree/App/DPadChat/lib/common.sh"
out=$(apply)

assert_says 'an incomplete tree hands off to the old launcher' "$out" 'handed off to old'
assert_eq 'an incomplete tree leaves the old app running' \
    "$(cat "$WORK_DIR/install/app/config.json")" '{"old": true}'

# No marker at all is the ordinary launch, and must not be an error.
build_install
rm -rf "$WORK_DIR/install/app/data/update/tree"
out=$(apply)
assert_says 'nothing staged hands off to the old launcher' "$out" 'handed off to old'
assert_eq 'nothing staged changes nothing' \
    "$(cat "$WORK_DIR/install/app/config.json")" '{"old": true}'

# -----------------------------------------------------------------------------
# The launcher
# -----------------------------------------------------------------------------

# launch.sh must hand off with `exec`, or it carries on reading its own file
# while the installer overwrites it.
launcher=$(cat "$REPO_ROOT/app/launch.sh")
assert_says 'the launcher execs the installer' "$launcher" 'exec "$STAGE_DIR/apply.sh"'

installer=$(cat "$REPO_ROOT/app/apply-update.sh")
assert_says 'the installer execs the launcher' "$installer" 'exec "$APP_DIR/launch.sh"'

# The token would be readable in `ps` by anything else on the device.
updater=$(cat "$REPO_ROOT/app/lib/update.sh")
refute_says 'the token never reaches the command line' "$updater" '--header "Authorization'
assert_says 'the download is pinned to the bundled CA' "$updater" 'cacert ='
assert_says 'redirects may not leave https' "$updater" 'proto-redir'

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
