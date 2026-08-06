#!/bin/sh
# Install the app onto a mounted SD card, or push it to a device over SSH.
#
#   tools/install.sh /media/user/MIYOO        copy to a mounted card
#   tools/install.sh --ssh 192.168.1.42       rsync over Onion's dropbear
#
# Runtime state under app/data is deliberately not copied: it holds the API key
# and conversation history, which belong to the device, not to the checkout.

set -eu

APP_NAME='DPadChat'
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
    host="$1"
    command -v rsync >/dev/null 2>&1 || fail 'rsync is required for --ssh'
    dest="root@$host:/mnt/SDCARD/App/$APP_NAME/"

    printf 'Installing to %s\n' "$dest"
    rsync -av --delete --exclude 'data/' "$SRC/" "$dest"
    printf 'Done. Relaunch from the Apps menu, or run:\n'
    printf '  ssh root@%s /mnt/SDCARD/App/%s/chat.sh\n' "$host" "$APP_NAME"
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
