#!/bin/sh
# Install the app onto a mounted SD card, or push it to a device over SSH.
#
# Runtime state under app/data is deliberately not copied: it holds the API key
# and the transcript, which belong to the device rather than to the checkout.
# The key is installed separately, by --key, so a stale developer key can never
# be swept onto a device by a routine sync.

set -eu

APP_NAME='DPadChat'
REMOTE_APP="/mnt/SDCARD/App/$APP_NAME"

# Onion ships two accounts (see its config/passwd): root, whose password is not
# documented anywhere, and onion, which the project's own SSH instructions use.
# Default to the one users are actually told about; both can write to the card.
SSH_USER="${DPAD_SSH_USER:-onion}"

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
SRC="$REPO_ROOT/app"

SSH_OPTS=''
SSH_TARGET=''
CTL_DIR=''

usage() {
    cat <<USAGE
Install D-Pad Chat.

  tools/install.sh /media/you/MIYOO          copy to a mounted SD card
  tools/install.sh --ssh 192.168.1.42        push over SSH
  tools/install.sh --ssh 192.168.1.42 --key  ...and set the API key
  tools/install.sh --ssh you@192.168.1.42    override the login

Options:
  --key             prompt for an API key and install it on the device
  --key-file PATH   read the key from a file instead of prompting

The default login is '$SSH_USER'; Onion's default password is also 'onion'.
Enable SSH under Tweaks > Network. Set DPAD_SSH_USER to change the login.
USAGE
    exit "${1:-0}"
}

fail() {
    printf 'install: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$CTL_DIR" ]; then
        # Close the shared connection rather than leaving it open for the rest
        # of its persist window after this script has exited.
        if [ -n "$SSH_TARGET" ]; then
            # shellcheck disable=SC2086
            ssh $SSH_OPTS -O exit "$SSH_TARGET" 2>/dev/null || :
        fi
        rm -rf "$CTL_DIR"
    fi
}

# -----------------------------------------------------------------------------
# API key
# -----------------------------------------------------------------------------

# Reads a key from stdin and prints the settings file that should replace the
# one at $1. Only api_key is rewritten, so a model or timeout chosen on the
# device survives a reinstall.
#
# Reachable as --merge-settings so it can be tested without a device attached.
merge_settings() {
    existing="$1"

    IFS= read -r key || key=''
    [ -n "$key" ] || fail 'no key supplied'

    # A key containing whitespace or control characters is a paste accident. It
    # would silently produce a settings file the app cannot parse.
    case "$key" in
        *[!!-~]*) fail 'the key contains spaces or control characters' ;;
    esac

    if [ -f "$existing" ]; then
        # Drop any previous api_key line, including hand-edited spacing, while
        # leaving comments and every other setting untouched.
        grep -v '^[[:space:]]*api_key[[:space:]]*=' "$existing" || :
    fi

    printf 'api_key=%s\n' "$key"
}

# The key is never passed as an argument: that would put it in `ps`, in the
# calling shell's history, and in any CI log. It is read with echo disabled and
# handed onward through a pipe.
prompt_for_key() {
    printf 'Paste the API key (input hidden), then press Enter.\n' >&2
    printf '  key> ' >&2

    if [ -t 0 ]; then
        stty_saved=$(stty -g 2>/dev/null) || stty_saved=''
        [ -z "$stty_saved" ] || stty -echo
        IFS= read -r key || key=''
        [ -z "$stty_saved" ] || stty "$stty_saved"
        printf '\n' >&2
    else
        IFS= read -r key || key=''
    fi

    [ -n "$key" ] || fail 'no key entered'
    printf '%s\n' "$key"
}

install_key() {
    if [ -n "$KEY_FILE" ]; then
        key=$(head -n 1 "$KEY_FILE" | tr -d '\r\n')
        [ -n "$key" ] || fail "$KEY_FILE is empty"
    else
        key=$(prompt_for_key)
    fi

    existing="$CTL_DIR/settings.cfg"
    merged="$CTL_DIR/merged.cfg"

    printf 'Reading existing settings\n'
    # SSH_OPTS is a word list and must split. REMOTE_APP is a local constant
    # that is meant to expand here, before the command is sent.
    # shellcheck disable=SC2086,SC2029
    ssh $SSH_OPTS "$SSH_TARGET" "cat $REMOTE_APP/data/settings.cfg 2>/dev/null" \
        >"$existing" 2>/dev/null || :

    (umask 077 && printf '%s\n' "$key" | merge_settings "$existing" >"$merged")

    printf 'Installing the key\n'
    # Sent over stdin, so it does not appear in the remote process list either.
    # shellcheck disable=SC2086,SC2029
    ssh $SSH_OPTS "$SSH_TARGET" \
        "mkdir -p $REMOTE_APP/data && cat > $REMOTE_APP/data/settings.cfg && (chmod 600 $REMOTE_APP/data/settings.cfg 2>/dev/null || true)" \
        <"$merged" || fail 'could not write the settings file'

    rm -f "$merged" "$existing"
    printf 'Key installed. Check it with /about on the device.\n'
}

# -----------------------------------------------------------------------------
# Install targets
# -----------------------------------------------------------------------------

install_ssh() {
    command -v rsync >/dev/null 2>&1 || fail 'rsync is required for --ssh'
    command -v ssh >/dev/null 2>&1 || fail 'ssh is required for --ssh'

    # Accept either "host" or "user@host"; only supply a default login when the
    # caller has not chosen one.
    case "$1" in
        *@*) SSH_TARGET="$1" ;;
        *) SSH_TARGET="$SSH_USER@$1" ;;
    esac

    # One authentication for the whole run. Without multiplexing this prompts
    # once per rsync and once per ssh, which is three password prompts for an
    # install that also sets a key.
    CTL_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
    chmod 700 "$CTL_DIR"
    SSH_OPTS="-o ControlMaster=auto -o ControlPath=$CTL_DIR/cm -o ControlPersist=120"

    printf 'Installing to %s:%s\n' "$SSH_TARGET" "$REMOTE_APP"
    printf 'The password is the device password, not your machine or WiFi one.\n'
    printf 'Onion default: %s / onion. Enable SSH in Tweaks > Network.\n\n' "$SSH_USER"

    # -a would imply -o -g -D, and preserving ownership needs root. As uid 1000
    # every chown fails and rsync exits 23 even though the transfer worked.
    # Ownership is meaningless on the card's FAT32 anyway.
    rsync -rlptv --delete --exclude 'data/' \
        -e "ssh $SSH_OPTS" "$SRC/" "$SSH_TARGET:$REMOTE_APP/"

    if [ "$WITH_KEY" -eq 1 ]; then
        printf '\n'
        install_key
    fi

    printf '\nDone. Open Apps > D-Pad Chat, or run:\n'
    printf '  ssh -t %s %s/chat.sh\n' "$SSH_TARGET" "$REMOTE_APP"
}

install_card() {
    root="$1"
    [ -d "$root" ] || fail "not a directory: $root"

    # An Onion card always has a top-level App directory. Without this check a
    # mistyped path scatters the app across an arbitrary folder.
    [ -d "$root/App" ] || fail "no App/ directory in $root - is this an Onion SD card?"

    dest="$root/App/$APP_NAME"
    printf 'Installing to %s\n' "$dest"

    mkdir -p "$dest"
    (cd "$SRC" && find . -path ./data -prune -o -type f -print) |
        while IFS= read -r rel; do
            mkdir -p "$dest/$(dirname "$rel")"
            cp "$SRC/$rel" "$dest/$rel"
        done

    # FAT32 carries no permission bits, but setting them keeps a card imaged
    # onto a Linux filesystem working, and is harmless otherwise.
    chmod 755 "$dest/launch.sh" "$dest/chat.sh" "$dest/apply-update.sh" \
        "$dest/uninstall.sh" 2>/dev/null || :

    printf 'Done. Eject the card and open Apps > D-Pad Chat.\n'
}

# -----------------------------------------------------------------------------

main() {
    WITH_KEY=0
    KEY_FILE=''
    SSH_HOST=''
    CARD=''

    [ $# -ge 1 ] || usage 1

    while [ $# -gt 0 ]; do
        case "$1" in
            -h | --help)
                usage 0
                ;;
            --ssh)
                [ $# -ge 2 ] || fail '--ssh needs a host'
                SSH_HOST="$2"
                shift 2
                ;;
            --key)
                WITH_KEY=1
                shift
                ;;
            --key-file)
                [ $# -ge 2 ] || fail '--key-file needs a path'
                # Checked here rather than at the point of use: the key is
                # installed after the transfer, so a typo would otherwise
                # surface only once rsync had finished.
                [ -f "$2" ] || fail "no such file: $2"
                KEY_FILE="$2"
                WITH_KEY=1
                shift 2
                ;;
            --merge-settings)
                [ $# -ge 2 ] || fail '--merge-settings needs a path'
                merge_settings "$2"
                return 0
                ;;
            -*)
                fail "unknown option: $1"
                ;;
            *)
                CARD="$1"
                shift
                ;;
        esac
    done

    trap cleanup EXIT INT TERM

    if [ -n "$SSH_HOST" ]; then
        [ -z "$CARD" ] || fail 'give either a card path or --ssh, not both'
        install_ssh "$SSH_HOST"
    elif [ -n "$CARD" ]; then
        [ "$WITH_KEY" -eq 0 ] ||
            fail '--key only applies to --ssh; edit data/settings.cfg on the card'
        install_card "$CARD"
    else
        usage 1
    fi
}

main "$@"
