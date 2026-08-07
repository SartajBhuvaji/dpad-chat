#!/bin/sh
# Restart the device over SSH, leaving nothing running.
#
# Holding POWER is already a safe shutdown, and Onion auto-saves the game before
# it goes down. What it does not reliably give you is a *clean* boot: Onion
# records what was running in .tmp_update/cmd_to_run.sh and replays it, which is
# why a power cycle mid-game comes back into the game.
#
# What is known about that file, and what is not:
#
#   - It was absent while a game was running, and absent again just after a
#     boot. Both were measured on a device, not read somewhere.
#   - Onion's FAQ has you delete it to escape a ROM that black-screens on every
#     boot - and has you do it with the card in a PC, not over SSH.
#
# The reading that fits all of that is that it is written as the device shuts
# down and consumed at boot when it is replayed, so it exists only while the
# device is off. Which means the clear below is not what makes a restart come up
# clean: by the time this runs there is normally nothing there to clear. It
# catches a stale one left by an unclean shutdown, which is exactly the
# boot-loop case, and that is worth doing on its own.
#
# Whether a restart from here lets Onion write a fresh one on the way down is
# not established. busybox reboot signals init, init signals everything else,
# and whether MainUI does its usual bookkeeping on the way out is not something
# this script can see. It is one experiment away - start a game, run this, see
# where it comes back - and the answer changes nothing about what to run, only
# what to claim.
#
# So this is three things in order: clear any stale auto-resume, flush the card,
# restart.
#
# It costs whatever the running emulator has not written. That is the point -
# the app's own rule is that nothing it does may cost the user their game, and
# this is a tool that deliberately breaks it, so it asks first.

set -eu

# Onion's card mount, and the directory whose presence tells the app it is on a
# device. Required to exist before anything is done, so a mistyped host that
# happens to answer SSH is refused rather than restarted.
#
# Overridable only so the tests can aim the generated script at a directory
# standing in for a card. Nothing on a device sets it.
REMOTE_CARD="${DPAD_REMOTE_CARD:-/mnt/SDCARD}"

# Onion ships two accounts; this is the one the project's own SSH instructions
# use. Matches tools/install.sh.
SSH_USER="${DPAD_SSH_USER:-onion}"

SSH_OPTS=''
SSH_TARGET=''
CTL_DIR=''

usage() {
    cat <<USAGE
Restart the device, with nothing left running.

  tools/reboot.sh 192.168.1.42            restart
  tools/reboot.sh you@192.168.1.42        override the login
  tools/reboot.sh --off 192.168.1.42      shut down instead of restarting

Options:
  --off             power off rather than restart
  --keep-resume     leave a stale auto-resume file alone rather than clearing it
  --yes             do not ask
  --print-remote    print what would run on the device, and stop

Unsaved game progress is lost: this does not wait for the emulator to write a
save state the way holding POWER does.

The default login is '$SSH_USER'; Onion's default password is also 'onion'.
Enable SSH under Tweaks > Network. Set DPAD_SSH_USER to change the login.
USAGE
    exit "${1:-0}"
}

fail() {
    printf 'reboot: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$CTL_DIR" ]; then
        if [ -n "$SSH_TARGET" ]; then
            # shellcheck disable=SC2086
            ssh $SSH_OPTS -O exit "$SSH_TARGET" 2>/dev/null || :
        fi
        rm -rf "$CTL_DIR"
    fi
}

# -----------------------------------------------------------------------------
# What runs on the device
# -----------------------------------------------------------------------------

# Everything except the restart itself, which is fired separately.
#
# Splitting it that way is what makes this testable: the half with decisions in
# it can be run here, against a directory standing in for the card, without
# restarting anything - and the half that cannot be tested is one word with no
# logic in it. --print-remote is how the tests get at it.
#
# The first heredoc is expanded, to carry the settings in; the second is quoted,
# so the device's shell sees the script rather than this one interpreting it.
remote_script() {
    cat <<REMOTE
set -u
CARD='$REMOTE_CARD'
ACTION='$ACTION'
KEEP_RESUME=$KEEP_RESUME
REMOTE

    cat <<'REMOTE'
# An Onion card always has this. Without the check, a host that is not the
# device - a typo landing on a real machine - would be restarted instead.
if [ ! -d "$CARD/.tmp_update" ]; then
    echo "not-onion: no $CARD/.tmp_update, refusing"
    exit 4
fi

if ! command -v "$ACTION" >/dev/null 2>&1; then
    echo "missing: no $ACTION on this device"
    exit 3
fi

# Onion records what was running here and replays it on the next boot. On a
# device that shut down cleanly this is normally absent - it appears to be
# consumed when it is replayed - so "was not set" is the ordinary answer and
# not a sign anything went wrong. What this catches is one left behind, which
# is Onion's own documented way out of a ROM that black-screens every time it
# resumes.
resume="$CARD/.tmp_update/cmd_to_run.sh"

if [ "$KEEP_RESUME" -eq 1 ]; then
    echo 'resume: left alone'
elif [ ! -f "$resume" ]; then
    echo 'resume: nothing to clear'
elif rm -f "$resume"; then
    echo 'resume: cleared'
else
    # Not fatal. A card mounted read-only still restarts; it just comes back
    # where it was, which is worth saying rather than failing over.
    echo 'resume: could not be cleared, this may boot back into the game'
fi

# The card is FAT32 and the writes above are the app's, Onion's, and ours.
# Pulling the power out from under them is how cards get corrupted.
sync
echo 'sync: ok'
REMOTE
}

# -----------------------------------------------------------------------------
# Doing it
# -----------------------------------------------------------------------------

confirm() {
    printf 'This %s %s now.\n' \
        "$([ "$ACTION" = 'reboot' ] && printf 'restarts' || printf 'shuts down')" \
        "$SSH_TARGET"
    printf 'Any unsaved game progress is lost.\n'

    if [ "$KEEP_RESUME" -eq 1 ]; then
        printf 'Any stale auto-resume is left alone.\n'
    else
        printf 'Any stale auto-resume is cleared.\n'
    fi

    printf '\n%s? [y/N] ' \
        "$([ "$ACTION" = 'reboot' ] && printf 'Restart' || printf 'Shut down')"

    # A closed pipe is not consent, which is the same rule the app's own
    # confirmations use. --yes is how a script says yes on purpose.
    [ -t 0 ] || { printf '\nno\n'; return 1; }

    IFS= read -r answer || answer=''
    case "$answer" in
        y | Y | yes | Yes | YES) return 0 ;;
        *) return 1 ;;
    esac
}

run_ssh() {
    command -v ssh >/dev/null 2>&1 || fail 'ssh is required'

    # Accept either "host" or "user@host", supplying a login only when the
    # caller has not chosen one.
    case "$1" in
        *@*) SSH_TARGET="$1" ;;
        *) SSH_TARGET="$SSH_USER@$1" ;;
    esac

    # One authentication for both calls, rather than a password prompt each.
    CTL_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
    chmod 700 "$CTL_DIR"
    SSH_OPTS="-o ControlMaster=auto -o ControlPath=$CTL_DIR/cm -o ControlPersist=60"

    if [ "$ASSUME_YES" -eq 0 ]; then
        confirm || fail 'cancelled'
        printf '\n'
    fi

    # The part that can fail, and reports why. Sent on stdin so no part of it
    # reaches the remote process list.
    # shellcheck disable=SC2086
    remote_script | ssh $SSH_OPTS "$SSH_TARGET" 'sh -s' ||
        fail 'the device refused, and nothing was restarted'

    # And the part that cannot be checked, because a successful one takes the
    # connection with it. Backgrounded behind a short sleep so ssh can close
    # cleanly first, and its exit status is ignored either way: a dropped
    # connection here is what success looks like.
    #
    # ACTION is meant to expand here, before the command is sent: it is one of
    # two words this script chose, not anything the device knows about.
    # shellcheck disable=SC2086,SC2029
    ssh $SSH_OPTS "$SSH_TARGET" \
        "nohup sh -c 'sleep 1; $ACTION' >/dev/null 2>&1 &" >/dev/null 2>&1 || :

    printf '%s: sent\n' "$ACTION"
    printf 'The device goes down in a second and comes back on its own.\n'
}

# -----------------------------------------------------------------------------

main() {
    ACTION='reboot'
    KEEP_RESUME=0
    ASSUME_YES=0
    PRINT_ONLY=0
    HOST=''

    while [ $# -gt 0 ]; do
        case "$1" in
            -h | --help) usage 0 ;;
            --off) ACTION='poweroff' ;;
            --keep-resume) KEEP_RESUME=1 ;;
            -y | --yes) ASSUME_YES=1 ;;
            --print-remote) PRINT_ONLY=1 ;;
            -*) fail "unknown option: $1" ;;
            *)
                [ -z "$HOST" ] || fail 'give one host'
                HOST="$1"
                ;;
        esac
        shift
    done

    if [ "$PRINT_ONLY" -eq 1 ]; then
        remote_script
        return 0
    fi

    [ -n "$HOST" ] || usage 1

    trap cleanup EXIT INT TERM
    run_ssh "$HOST"
}

main "$@"
