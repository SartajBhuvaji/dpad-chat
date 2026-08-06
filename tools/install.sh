#!/bin/sh
# Install the app onto a mounted SD card, or push it to a device over SSH.
#
#   tools/install.sh /media/user/MIYOO        copy to a mounted card
#   tools/install.sh --ssh 192.168.1.42       rsync over Onion's dropbear
#   tools/install.sh --ssh me@192.168.1.42    override the login
#
# Runtime state under app/data is deliberately not copied: it holds the API key
# and conversation history, which belong to the device, not to the checkout.

set -eu

APP_NAME='DPadChat'

# Onion ships two accounts (see its config/passwd): root, whose password is not
# documented, and onion, which the project's own SSH instructions use. Default
# to the one users are actually told about; both have write access to the card.
SSH_USER="${DPAD_SSH_USER:-onion}"
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
SRC="$REPO_ROOT/app"

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

fail() {
    printf 'install: %s\n' "$*" >&2
    exit 1
}

install_ssh() {
    target="$1"
    command -v rsync >/dev/null 2>&1 || fail 'rsync is required for --ssh'

    # Accept either "host" or "user@host"; only supply a default login when the
    # caller did not choose one.
    case "$target" in
        *@*) ;;
        *) target="$SSH_USER@$target" ;;
    esac

    dest="$target:/mnt/SDCARD/App/$APP_NAME/"

    printf 'Installing to %s\n' "$dest"
    printf 'The password is the device password, not your machine or WiFi one.\n'
    printf 'Onion default: onion / onion. Enable SSH in Tweaks > Network.\n\n'

    # -a would imply -o -g -D, and preserving ownership needs root. The onion
    # account is uid 1000, so every chown fails and rsync exits 23 even though
    # the transfer worked. Ownership is meaningless on the card's FAT32 anyway.
    rsync -rlptv --delete --exclude 'data/' "$SRC/" "$dest"

    printf '\nDone. Relaunch from the Apps menu, or run:\n'
    printf '  ssh %s /mnt/SDCARD/App/%s/chat.sh\n' "$target" "$APP_NAME"
}

install_card() {
    root="$1"
    [ -d "$root" ] || fail "Not a directory: $root"

    # Guard against copying into an arbitrary folder: an Onion card always has
    # a top-level App directory, and getting this wrong scatters files.
    [ -d "$root/App" ] || fail "No App/ directory in $root - is this an Onion SD card?"

    dest="$root/App/$APP_NAME"
    printf 'Installing to %s\n' "$dest"

    mkdir -p "$dest"
    # -R preserves the lib/ and res/ layout; data/ is filtered out below.
    (cd "$SRC" && find . -path ./data -prune -o -type f -print) |
        while IFS= read -r rel; do
            mkdir -p "$dest/$(dirname "$rel")"
            cp "$SRC/$rel" "$dest/$rel"
        done

    # FAT32 carries no permission bits, but setting them keeps a card imaged
    # onto a Linux filesystem working, and is harmless otherwise.
    chmod 755 "$dest/launch.sh" "$dest/chat.sh" 2>/dev/null || :

    printf 'Done. Eject the card and open Apps > D-Pad Chat.\n'
}

main() {
    [ $# -ge 1 ] || usage 1

    case "$1" in
        -h | --help)
            usage 0
            ;;
        --ssh)
            [ $# -eq 2 ] || fail 'usage: install.sh --ssh <host>'
            install_ssh "$2"
            ;;
        -*)
            fail "Unknown option: $1"
            ;;
        *)
            install_card "$1"
            ;;
    esac
}

main "$@"
