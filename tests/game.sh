#!/bin/sh
# Checks for reading what is being played out of Onion's recently-played list.
#
# tests/fixtures/recentlist.json is a real one, taken off a card in exactly the
# state this feature exists for: Road Rash being played, Menu pressed to come
# out of it, nothing else done in between. Only `imgpath` and `launch` on the
# first entry were filled back in - they were elided when the sample was
# recorded, and nothing here reads them. Everything else is as the device wrote
# it, which is worth more than an invented file: the parser is written against
# bytes Onion actually produced.

# Resolve sourced files relative to this script. Must precede the first command
# to apply file-wide.
# shellcheck source-path=SCRIPTDIR

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
FIXTURE="$REPO_ROOT/tests/fixtures/recentlist.json"

TESTS_RUN=0
TESTS_FAILED=0

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dpad)
trap 'rm -rf "$WORK_DIR"' EXIT

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

assert_contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "expected to find '$3' in '$2'" ;;
    esac
}

assert_not_contains() {
    case "$2" in
        *"$3"*) fail "$1" "did not expect '$3' in '$2'" ;;
        *) pass "$1" ;;
    esac
}

# -----------------------------------------------------------------------------

printf 'Running game tests\n'

# A card, shaped the way the device's is: Onion's bundled tree beside the roms.
# DPAD_SYSDIR points the app at the first, and the list is found relative to it.
CARD="$WORK_DIR/card"
mkdir -p "$CARD/.tmp_update" "$CARD/Roms"

# Runs the module against the card as it currently stands, and prints the name
# it found followed by the return code, so "found nothing" and "returned
# nothing" cannot be confused for each other.
#
# A plain subshell rather than a command substitution, so the environment each
# case sets up cannot follow the next one out.
name_now() {
    (
        DPAD_SYSDIR="$CARD/.tmp_update"
        export DPAD_SYSDIR
        # shellcheck source=../app/lib/common.sh
        . "$REPO_ROOT/app/lib/common.sh"
        # shellcheck source=../app/lib/game.sh
        . "$REPO_ROOT/app/lib/game.sh"

        game_init
        if game_name; then
            printf ':0'
        else
            printf ':1'
        fi
    )
}

# The same, with $1 written to the list first. An unquoted `-` leaves the file
# out altogether.
name_from() {
    if [ "$1" = '-' ]; then
        rm -f "$CARD/Roms/recentlist.json"
    else
        printf '%s' "$1" >"$CARD/Roms/recentlist.json"
    fi

    name_now
}

# Where the module decided the list lives, for a given sysdir. An unquoted `-`
# leaves DPAD_SYSDIR unset, which is the device's own case and the one no test
# can reach by pointing somewhere else.
list_path() {
    (
        if [ "$1" = '-' ]; then
            unset DPAD_SYSDIR
        else
            DPAD_SYSDIR="$1"
            export DPAD_SYSDIR
        fi

        # shellcheck source=../app/lib/common.sh
        . "$REPO_ROOT/app/lib/common.sh"
        # shellcheck source=../app/lib/game.sh
        . "$REPO_ROOT/app/lib/game.sh"

        game_init
        printf '%s' "$GAME_RECENTLIST"
    )
}

# -----------------------------------------------------------------------------
# The recorded sample
# -----------------------------------------------------------------------------

printf '\nThe card as it was read\n'

assert_eq 'the game being played is found' \
    "$(name_from "$(cat "$FIXTURE")")" 'Road Rash (USA, Europe):0'

# The whole of stage B, demonstrated on the real file: launching the app at
# that moment produces a suggestion about the right game.

printf '\nWhere the list is looked for\n'

assert_eq 'the list is found beside the roms, not under the app' \
    "$(list_path "$CARD/.tmp_update" | sed "s|^$CARD/||")" 'Roms/recentlist.json'

assert_eq 'and on a device that is the card root' \
    "$(list_path '-')" '/mnt/SDCARD/Roms/recentlist.json'

# A trailing slash on the sysdir would otherwise take the card root off by one
# directory and look for the list inside Onion's own tree.
assert_eq 'a trailing slash does not shift the root' \
    "$(list_path '/mnt/SDCARD/.tmp_update/')" '/mnt/SDCARD/Roms/recentlist.json'

# -----------------------------------------------------------------------------
# Telling a game from an app
# -----------------------------------------------------------------------------

printf '\nTelling a game from an app\n'

APP_ENTRY='{"label":"D-Pad Chat","launch":"/mnt/SDCARD/App/DPadChat/launch.sh","type":3}'
GAME_ENTRY='{"label":"Chrono Trigger (USA)","rompath":"/mnt/SDCARD/Emu/SFC/launch.sh:/x.zip","type":5}'

# The case the discriminator exists for. Whether Onion writes our entry when an
# app is launched or when it exits was never established, so the answer must
# not depend on it - reading "the most recent entry" would give this app's own
# name back as the game being played.
assert_eq 'this app is skipped even when it is first' \
    "$(name_from "$APP_ENTRY
$GAME_ENTRY")" 'Chrono Trigger (USA):0'

assert_eq 'and when it is last' \
    "$(name_from "$GAME_ENTRY
$APP_ENTRY")" 'Chrono Trigger (USA):0'

assert_eq 'a list of nothing but apps names no game' \
    "$(name_from "$APP_ENTRY
$APP_ENTRY")" ':1'

# `type` is 5 against 3 in the sample, but those are numbers whose meaning we
# would be guessing at, and there is no reason to think they enumerate only
# those two things. A game with an unfamiliar type is still a game.
assert_eq 'an unfamiliar type is not what decides it' \
    "$(name_from '{"label":"Something New","rompath":"/a:/b","type":9}')" \
    'Something New:0'

# -----------------------------------------------------------------------------
# Failing quietly
# -----------------------------------------------------------------------------

printf '\nFailing quietly\n'

# Onion's working state, not a published interface: it may move, be renamed or
# change shape in a version nobody here has seen. Every one of these has to
# mean "no suggestion" rather than an error, or an Onion update would take the
# app down with the feature.

assert_eq 'no list at all is not an error' "$(name_from '-')" ':1'
assert_eq 'an empty list is not an error' "$(name_from '')" ':1'
assert_eq 'a list of blank lines is not an error' "$(name_from '

')" ':1'

assert_eq 'nothing that is not JSON gets through' \
    "$(name_from 'this is not json at all')" ':1'

assert_eq 'nor a JSON document of the wrong shape' \
    "$(name_from '["Road Rash", "Chrono Trigger"]')" ':1'

# A truncated write - the device losing power mid-update is the obvious way -
# leaves a half-written line. jq stops there, but what it printed before still
# arrives, and the entry wanted is the first.
assert_eq 'a truncated line does not lose the entries above it' \
    "$(name_from "$GAME_ENTRY
{\"label\":\"Half Writt")" 'Chrono Trigger (USA):0'

assert_eq 'a game with no label is skipped' \
    "$(name_from '{"rompath":"/a:/b","type":5}
'"$GAME_ENTRY")" 'Chrono Trigger (USA):0'

assert_eq 'and one whose label is not a string' \
    "$(name_from '{"label":null,"rompath":"/a:/b"}
{"label":7,"rompath":"/a:/b"}
'"$GAME_ENTRY")" 'Chrono Trigger (USA):0'

assert_eq 'and one whose label is empty' \
    "$(name_from '{"label":"","rompath":"/a:/b"}
'"$GAME_ENTRY")" 'Chrono Trigger (USA):0'

# A directory where the file should be is what a future Onion reorganising
# this would most plausibly leave behind.
rm -f "$CARD/Roms/recentlist.json"
mkdir -p "$CARD/Roms/recentlist.json"
assert_eq 'a directory in its place is not an error' "$(name_now)" ':1'
rmdir "$CARD/Roms/recentlist.json"

# -----------------------------------------------------------------------------
# Tidying the name
# -----------------------------------------------------------------------------

printf '\nTidying the name\n'

strip() {
    (
        # shellcheck source=../app/lib/game.sh
        . "$REPO_ROOT/app/lib/game.sh"
        game_strip_tags "$1"
    )
}

assert_eq 'a region tag goes' "$(strip 'Road Rash (USA, Europe)')" 'Road Rash'
assert_eq 'and so do several' "$(strip 'Game (USA) (Rev 1)')" 'Game'
assert_eq 'brackets go too' "$(strip 'Wario Land 3 [!]')" 'Wario Land 3'
assert_eq 'mixed, in any order' "$(strip 'Zelda [!] (USA) [b1]')" 'Zelda'
assert_eq 'a plain title is left alone' "$(strip 'Chrono Trigger')" 'Chrono Trigger'

# Brackets inside the title are not trailing metadata and stay.
assert_eq 'a group in the middle stays' \
    "$(strip 'Mega Man (X) Legacy')" 'Mega Man (X) Legacy'

# Never down to nothing: a suggestion about a game with no name would be worse
# than no suggestion.
assert_eq 'a title that is nothing but a tag keeps it' \
    "$(strip '(Homebrew)')" '(Homebrew)'
assert_eq 'and one that is nothing but tags' "$(strip '(USA) (Rev 1)')" '(USA)'

# A closing bracket with nothing opening it is part of the title, not a tag.
assert_eq 'an unmatched bracket is left alone' \
    "$(strip 'What Is This)')" 'What Is This)'

assert_eq 'trailing space goes with the tag' \
    "$(strip 'Road Rash (USA)   ')" 'Road Rash'
assert_eq 'and a name that is only spaces survives it' "$(strip '   ')" ''

# -----------------------------------------------------------------------------
# The whole chain, through the app
# -----------------------------------------------------------------------------

printf '\nThrough the app\n'

# Everything above is a unit. This is the only check that proves the pieces are
# wired to each other: a real card, the real app, a real terminal, and the
# suggestion arriving at the prompt with the right name in it.
cp "$FIXTURE" "$CARD/Roms/recentlist.json"

app_prompt() {
    DPAD_SYSDIR="$CARD/.tmp_update" \
        DPAD_DATA_DIR="$WORK_DIR/data" \
        COLUMNS=53 LINES=29 \
        "$REPO_ROOT/tests/keys.py" --cols 53 --rows 29 --input "$1" \
        -- "$REPO_ROOT/app/chat.sh" 2>/dev/null || :
}

if ! command -v python3 >/dev/null 2>&1; then
    printf '  skipped: python3 not installed\n'
else
    rm -rf "$WORK_DIR/data"
    out=$(app_prompt '/quit\r')
    assert_contains 'the prompt offers the game that was being played' \
        "$out" "I'm playing Road Rash -"
    assert_not_contains 'with the region tag left off' "$out" 'USA, Europe'

    # Right takes it, and what it takes is what gets sent. No key is set, so
    # the send stops at the client - but the question it stopped with is the
    # accepted text plus what was typed after it, which is the whole point.
    rm -rf "$WORK_DIR/data"
    out=$(app_prompt '\033[Chow do I win\r/quit\r')
    assert_contains 'Right accepts it into a real message' \
        "$out" "I'm playing Road Rash - how do I win"
    assert_contains 'which reaches the responder' "$out" 'No API key set'

    # Dismissing must leave the app exactly as it was before the feature.
    rm -rf "$WORK_DIR/data"
    out=$(app_prompt '/about\r/quit\r')
    assert_not_contains 'and typing over it sends none of it' \
        "$out" "I'm playing Road Rash - /about"

    # An explicit suggestion is the user's own words and outranks the game.
    rm -rf "$WORK_DIR/data"
    out=$(DPAD_SUGGEST='Explain this to me' app_prompt '/quit\r')
    assert_contains 'an explicit suggestion wins' "$out" 'Explain this to me'
    assert_not_contains 'and the game is not offered as well' "$out" 'Road Rash'

    # The off switch, through the settings file, which is the route a user has.
    # Turning game-awareness off must not turn the prompt off with it.
    rm -rf "$WORK_DIR/data"
    mkdir -p "$WORK_DIR/data"
    printf 'suggest_game =\n' >"$WORK_DIR/data/settings.cfg"
    out=$(app_prompt '/quit\r')
    assert_not_contains 'an emptied template offers nothing' "$out" 'Road Rash'
    assert_not_contains 'and is not a setting the app complains about' \
        "$out" 'unknown setting'
    rm -f "$WORK_DIR/data/settings.cfg"

    rm -rf "$WORK_DIR/data"
    out=$(DPAD_SUGGEST_STRIP_TAGS='false' app_prompt '/quit\r')
    assert_contains 'and the tags can be kept' "$out" 'Road Rash (USA, Europe)'

    # A card with no list is a desktop, a fresh install, or an Onion that moved
    # the file. All three have to be the app as it was.
    rm -rf "$WORK_DIR/data"
    rm -f "$CARD/Roms/recentlist.json"
    out=$(app_prompt '/quit\r')
    assert_not_contains 'no list means no suggestion' "$out" "I'm playing"
    assert_contains 'and the app is otherwise itself' "$out" 'D-Pad Chat'
fi

# -----------------------------------------------------------------------------

printf '\n%s test(s), %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
