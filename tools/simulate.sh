#!/bin/sh
# Run the app on a development machine, shaped like the device.
#
# Pins the terminal to the Miyoo's column count and redirects writable state to
# a scratch directory, so a simulated run never touches the checked-in tree.
#
#   tools/simulate.sh              interactive
#   echo '/about' | tools/simulate.sh   scripted
#
# Set DPAD_COLS to try a different width; see PLAN.md section 11, item 2.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

COLUMNS="${DPAD_COLS:-40}"
export COLUMNS

DPAD_DATA_DIR="${DPAD_DATA_DIR:-${TMPDIR:-/tmp}/dpad-chat-sim}"
export DPAD_DATA_DIR

mkdir -p "$DPAD_DATA_DIR"

exec "$REPO_ROOT/app/chat.sh" "$@"
