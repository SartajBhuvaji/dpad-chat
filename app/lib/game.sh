#!/bin/sh
# What is being played, read out of Onion's own recently-played list.
#
# Onion already switches from a running game to an App when the Menu button is
# pressed, and the game is still there when you come back - so the whole
# mechanism for reaching this app mid-game exists and is somebody else's code.
# All that is left is to notice which game it was, which is a file read.
#
# The file is Onion's working state, not a published interface: it may move,
# be renamed or change shape in a version we have never seen. Everything here
# is therefore read-only and fails by returning nothing. A missing or
# unreadable list means no suggestion, and the app carries on being the app -
# there is no version of Onion this requires and nothing left behind on one
# that does not have it.

# -----------------------------------------------------------------------------
# Where the list is
# -----------------------------------------------------------------------------

# Derived from the same variable that tells the app it is on a device, rather
# than naming /mnt/SDCARD outright, so the tests aim both at a fixture tree by
# setting one thing. On a desktop the path simply is not there.
game_init() {
    _gi_root="${ONION_SYSDIR%/}"
    _gi_root="${_gi_root%/*}"

    GAME_RECENTLIST="$_gi_root/Roms/recentlist.json"
    return 0
}

# -----------------------------------------------------------------------------
# Reading it
# -----------------------------------------------------------------------------

# The name Onion itself displays for the most recently played game, or nothing.
# Returns non-zero when there is no answer, which is every case where the file
# is absent, unreadable, empty, or holds no game at all.
#
# The list is newline-delimited JSON - one object per line, with no enclosing
# array - which jq reads natively with no flags.
#
# Apps are in this list too, this one among them. Reading "the most recent
# entry" would therefore sometimes give a game and sometimes give us, depending
# on nothing more interesting than what was opened last. Games carry `rompath`
# and apps do not, so that is the discriminator, and being a property of the
# entry rather than of its position it is right whichever order Onion writes
# them in. It is also a better one than `type` - 5 for a game and 3 for an app
# in the sample, but those are numbers whose meaning we would be guessing at.
game_name() {
    [ -n "${GAME_RECENTLIST:-}" ] || return 1
    [ -f "$GAME_RECENTLIST" ] || return 1
    [ -r "$GAME_RECENTLIST" ] || return 1

    # A malformed line stops jq there, but whatever it printed first still
    # arrives - and the entry wanted is the first. head closes the pipe after
    # it, so a long list is not read to the end either.
    _gn_name=$(
        jq -r '
            select(type == "object")
            | select(has("rompath"))
            | .label
            | select(type == "string" and length > 0)
        ' "$GAME_RECENTLIST" 2>/dev/null | head -n 1
    )

    [ -n "$_gn_name" ] || return 1

    printf '%s' "$_gn_name"
    return 0
}

# Trailing groups in brackets are metadata in every ROM naming convention in
# use - region, revision, language, dump status - and read as noise in a
# sentence: "Road Rash (USA, Europe)" is a filename, "Road Rash" is a game.
#
# Stripped from the end only, repeatedly, and never down to nothing: a title
# that is entirely one group keeps it rather than vanishing. The risk is a
# title that legitimately ends in brackets, which is why suggest_strip_tags
# exists to turn this off.
game_strip_tags() {
    _gs="$1"

    while :; do
        _gs=$(_game_rtrim "$_gs")

        case "$_gs" in
            *')') _gs_cut="${_gs%(*}" ;;
            *']') _gs_cut="${_gs%"["*}" ;;
            *) break ;;
        esac

        # Unchanged means there was no opening bracket to match, so the closing
        # one is part of the title.
        [ "$_gs_cut" != "$_gs" ] || break

        _gs_cut=$(_game_rtrim "$_gs_cut")
        [ -n "$_gs_cut" ] || break

        _gs="$_gs_cut"
    done

    printf '%s' "$_gs"
}

_game_rtrim() {
    _gr="$1"
    while :; do
        case "$_gr" in
            *' ') _gr="${_gr% }" ;;
            *) break ;;
        esac
    done
    printf '%s' "$_gr"
}
