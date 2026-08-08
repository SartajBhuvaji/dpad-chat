#!/bin/sh
# D-Pad Chat - a chat client for Onion OS on the Miyoo Mini+.
#
# Runs inside Onion's bundled `st` terminal, which supplies the on-screen
# keyboard. See PLAN.md for the full design and milestone breakdown.
#
# Conversations persist across launches: relaunching resumes where you left off
# and replays the most recent turns, rather than starting over.

# Resolve sourced files relative to this script. Must precede the first command
# to apply file-wide; attached to a single command it only covers that line.
# shellcheck source-path=SCRIPTDIR

set -eu

APP_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
readonly APP_DIR

# shellcheck source=lib/common.sh
. "$APP_DIR/lib/common.sh"
# shellcheck source=lib/ui.sh
. "$APP_DIR/lib/ui.sh"
# shellcheck source=lib/screen.sh
. "$APP_DIR/lib/screen.sh"
# shellcheck source=lib/input.sh
. "$APP_DIR/lib/input.sh"
# shellcheck source=lib/config.sh
. "$APP_DIR/lib/config.sh"
# shellcheck source=lib/net.sh
. "$APP_DIR/lib/net.sh"
# shellcheck source=lib/history.sh
. "$APP_DIR/lib/history.sh"
# shellcheck source=lib/api.sh
. "$APP_DIR/lib/api.sh"
# shellcheck source=lib/update.sh
. "$APP_DIR/lib/update.sh"
# shellcheck source=lib/uninstall.sh
. "$APP_DIR/lib/uninstall.sh"
# shellcheck source=lib/game.sh
. "$APP_DIR/lib/game.sh"

DATA_DIR="${DPAD_DATA_DIR:-$APP_DIR/data}"
API_CACERT="${DPAD_CACERT:-$APP_DIR/res/cacert.pem}"

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

# The labels are padded to the longest command rather than to the shortest that
# fits, so the descriptions line up in a single column at 40 cols.
cmd_help() {
    ui_info '/help       this list'
    ui_info '/clear      start a new chat  (/c)'
    ui_info '/about      version and settings'
    ui_info '/config     change a setting  (/set)'
    ui_info '/update     check for a new version'
    ui_info '/uninstall  remove from the device'
    ui_info '/quit       exit'
    printf '\n'
    ui_info 'Chats are kept when you close the app.'
    printf '\n'
    ui_info 'X toggles the keyboard. Hide it to read'
    ui_info 'long replies.'

    if ! config_has_key; then
        printf '\n'
        ui_warn 'No API key set. Type /config api_key'
        ui_warn 'to enter one, or put api_key=<key> in'
        ui_warn "$DATA_DIR/settings.cfg"
    fi
}

cmd_about() {
    ui_info "version  $DPADCHAT_VERSION"
    # Both halves of the grid. The width alone left it ambiguous whether st
    # keeps a border - 53 columns rules one out across, but says nothing about
    # down, and the row count is what the status bars are pinned by.
    ui_info "width    ${UI_COLS} cols"
    ui_info "height   ${SCREEN_ROWS:-?} rows$(_about_rows_now)"
    if is_device; then
        ui_info 'host     Miyoo (Onion OS)'
    else
        ui_info 'host     development'
    fi
    ui_info "model    $CFG_MODEL"
    ui_info "key      $(config_redact_key)"
    ui_info "history  $(history_count) of $CFG_HISTORY_MESSAGES msgs"
    ui_info "stream   $CFG_STREAM"
    ui_info "tls      $(_about_tls)"
    ui_info "net      $(_about_net)"
    ui_info "data     $DATA_DIR"
}

# Only says anything when the terminal is not the height it was at startup.
# Nothing here resizes it, so a difference means something else did - and on
# this device the interesting candidate is st's on-screen keyboard, which is
# drawn over the screen rather than beside it and so should not resize
# anything at all.
_about_rows_now() {
    _ar_now=$(screen_rows_now)
    [ "$_ar_now" != "${SCREEN_ROWS:-}" ] || return 0
    printf ' (now %s)' "$_ar_now"
}

_about_tls() {
    case "$CFG_BASE_URL" in
        https://*)
            if [ -r "$API_CACERT" ]; then
                printf 'verified (%s certs)' \
                    "$(grep -c 'BEGIN CERTIFICATE' "$API_CACERT" 2>/dev/null || printf '?')"
            else
                printf 'MISSING BUNDLE'
            fi
            ;;
        *) printf 'not used (plain http)' ;;
    esac
}

_about_net() {
    if net_has_route; then
        printf 'route ok, clock %s' "$(clock_year)"
    else
        printf 'no route'
    fi
}

# An empty screen is the confirmation: reporting what was just discarded leaves
# the first thing in a new chat being a note about the old one. The failure is
# still announced, because silence there would look identical to success.
cmd_new() {
    if history_is_empty; then
        screen_clear
        chat_header
        return 0
    fi

    if history_reset "$CFG_SYSTEM_PROMPT"; then
        screen_clear
        chat_header
    else
        ui_error 'Could not clear the chat.'
    fi
}

# -----------------------------------------------------------------------------
# /config
# -----------------------------------------------------------------------------
#
# Only the settings that are cheap to change from here. A character costs
# around five button presses, so a command that makes you type a value is
# barely better than editing settings.cfg over SSH - the point of this is the
# ones you can cycle without typing anything but the command.
#
# The rest stay in the file on purpose: base_url and github_token are long and
# set once if ever, the timeouts are debugging knobs, replay_messages is
# cosmetic, and the suggest templates are free text that stage B fills in on
# its own. COMMANDS.md says so, so nobody has to guess why their setting is
# missing.
#
# api_key is the exception that earns its typing: it is what stands between a
# fresh install and never needing a computer at all.

# Cycle orders. Not a menu of everything that works - `/config model gpt-5`
# sets whatever you name. These are the few worth reaching with one press, and
# the list ages better as an order to walk than as a validation rule.
CONFIG_MODELS='gpt-4o-mini gpt-4o gpt-4.1-mini gpt-4.1'
CONFIG_MAX_TOKENS='256 512 1024 2048'
CONFIG_HISTORY='4 10 20 40'
CONFIG_BOOLS='true false'

# Every name /config will act on, which is also what it lists.
CONFIG_KEYS='model max_tokens history_messages stream suggest_strip_tags api_key'

# The next entry after $2 in the list $1, wrapping. A value that is not in the
# list - set by hand in the file, or by /config with an argument - lands on the
# first entry, which is the only answer that is always available.
_config_next() {
    _cn_first=''
    _cn_take=0

    for _cn_item in $1; do
        [ -n "$_cn_first" ] || _cn_first="$_cn_item"
        if [ "$_cn_take" -eq 1 ]; then
            printf '%s' "$_cn_item"
            return 0
        fi
        [ "$_cn_item" != "$2" ] || _cn_take=1
    done

    printf '%s' "$_cn_first"
}

# What a setting reads as now. api_key is redacted here exactly as it is in
# /about: the screen is the one place a photograph or a bug report catches it.
_config_show() {
    case "$1" in
        model) printf '%s' "$CFG_MODEL" ;;
        max_tokens) printf '%s' "$CFG_MAX_TOKENS" ;;
        history_messages) printf '%s' "$CFG_HISTORY_MESSAGES" ;;
        stream) printf '%s' "$CFG_STREAM" ;;
        suggest_strip_tags) printf '%s' "$CFG_SUGGEST_STRIP_TAGS" ;;
        api_key) config_redact_key ;;
    esac
}

_config_cycle() {
    case "$1" in
        model) _config_next "$CONFIG_MODELS" "$CFG_MODEL" ;;
        max_tokens) _config_next "$CONFIG_MAX_TOKENS" "$CFG_MAX_TOKENS" ;;
        history_messages) _config_next "$CONFIG_HISTORY" "$CFG_HISTORY_MESSAGES" ;;
        stream) _config_next "$CONFIG_BOOLS" "$CFG_STREAM" ;;
        suggest_strip_tags) _config_next "$CONFIG_BOOLS" "$CFG_SUGGEST_STRIP_TAGS" ;;
    esac
}

# Checked here rather than left to config_load's validation, because that runs
# at startup and repairs a bad value silently. Refusing at the point of typing
# is what tells somebody they typed it wrong.
_config_valid() {
    case "$1" in
        max_tokens | history_messages)
            case "$2" in
                '' | *[!0-9]*) return 1 ;;
            esac
            [ "$2" -gt 0 ] || return 1
            ;;
        stream | suggest_strip_tags)
            case "$2" in
                true | false) ;;
                *) return 1 ;;
            esac
            ;;
        model)
            # Anything printable with no spaces. A model name is sent straight
            # into the request body, and a space in one means a typo rather
            # than a model nobody has heard of.
            case "$2" in
                '' | *[!!-~]*) return 1 ;;
            esac
            ;;
    esac
    return 0
}

# Applies to the running session as well as the file. A setting that only took
# effect after a restart would be indistinguishable from one that did not work.
_config_apply() {
    case "$1" in
        model) CFG_MODEL="$2" ;;
        max_tokens) CFG_MAX_TOKENS="$2" ;;
        history_messages) CFG_HISTORY_MESSAGES="$2" ;;
        stream) CFG_STREAM="$2" ;;
        suggest_strip_tags) CFG_SUGGEST_STRIP_TAGS="$2" ;;
        api_key) CFG_API_KEY="$2" ;;
    esac
}

_config_store() {
    _cs_was=$(_config_show "$1")
    _config_apply "$1" "$2"

    if ! config_set "$1" "$2"; then
        # The session already has it, so say what was kept and what was not
        # rather than pretending either way.
        ui_error "Could not write $CONFIG_FILE"
        ui_info "$1 is set for this session only"
        return 1
    fi

    ui_info "$1  $_cs_was -> $(_config_show "$1")"
    return 0
}

# The key is never taken as an argument. The REPL puts every line it accepts
# into the recall list, so `/config api_key sk-...` would leave the key one
# press of Up away - and on screen above the prompt, where it stays until the
# transcript scrolls. Asking for it separately is what avoids both.
_config_ask_key() {
    printf '\n%sPaste or type the key, then Start.%s\n' "$C_DIM" "$C_RESET"
    printf '%sIt is not shown, and not remembered by Up.%s\n' "$C_DIM" "$C_RESET"
    printf '%s key> %s' "$C_USER" "$C_RESET"

    input_mask
    if ! input_readline 6; then
        printf '\n'
        return 1
    fi

    _ck_key=$(printf '%s' "$INPUT_LINE" | tr -d '[:space:]')

    if [ -z "$_ck_key" ]; then
        ui_info 'Nothing entered; the key is unchanged.'
        return 1
    fi

    # The same check tools/install.sh makes. A key with anything unprintable in
    # it is a mistyped paste, and it would come back as an authentication
    # failure with nothing pointing at the cause.
    case "$_ck_key" in
        *[!!-~]*)
            ui_error 'That contains characters a key cannot have; nothing was changed.'
            return 1
            ;;
    esac

    _config_store api_key "$_ck_key" || return 1
    return 0
}

cmd_config() {
    # The command, then a name, then a value - and the value may contain
    # spaces, so it is whatever is left rather than the third word.
    _cc_rest="${1#/config}"
    _cc_rest="${_cc_rest#"${_cc_rest%%[![:space:]]*}"}"

    _cc_name="${_cc_rest%%[[:space:]]*}"
    _cc_value=''
    case "$_cc_rest" in
        *[[:space:]]*)
            _cc_value="${_cc_rest#*[[:space:]]}"
            _cc_value=$(printf '%s' "$_cc_value" |
                sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            ;;
    esac

    if [ -z "$_cc_name" ]; then
        for _cc_k in $CONFIG_KEYS; do
            ui_info "$(printf '%-19s%s' "$_cc_k" "$(_config_show "$_cc_k")")"
        done
        printf '\n'
        ui_info '/config <name>          next value'
        ui_info '/config <name> <value>  set it'
        return 0
    fi

    # Named a setting that exists but is not one of these. Saying where it does
    # live beats "unknown", which reads as a typo.
    case " $CONFIG_KEYS " in
        *" $_cc_name "*) ;;
        *)
            case "$_cc_name" in
                base_url | github_token | connect_timeout | timeout | \
                    replay_messages | system_prompt | suggest | suggest_game)
                    ui_error "$_cc_name is not editable here"
                    ui_info "Edit $CONFIG_FILE to change it"
                    ;;
                *)
                    ui_error "No setting called $_cc_name"
                    ui_info '/config lists the ones you can change'
                    ;;
            esac
            return 0
            ;;
    esac

    if [ "$_cc_name" = 'api_key' ]; then
        # Deliberately ignores a value given inline; see _config_ask_key.
        _config_ask_key || :
        return 0
    fi

    if [ -z "$_cc_value" ]; then
        _cc_value=$(_config_cycle "$_cc_name")
    elif ! _config_valid "$_cc_name" "$_cc_value"; then
        ui_error "$_cc_value is not a value $_cc_name can take"
        case "$_cc_name" in
            stream | suggest_strip_tags) ui_info 'Use true or false' ;;
            max_tokens | history_messages) ui_info 'Use a whole number above zero' ;;
        esac
        return 0
    fi

    _config_store "$_cc_name" "$_cc_value" || :
    return 0
}

# Checking is always safe; installing is not, so it never happens without an
# answer at the prompt. What is downloaded is unpacked beside the app and left
# there: the swap belongs to launch.sh, where nothing from the app directory is
# running. See lib/update.sh for why that ordering is not optional.
cmd_update() {
    if update_is_pending; then
        ui_info 'An update is already downloaded.'
        ui_info 'Quit and reopen the app to finish it.'
        return 0
    fi

    if ! net_has_route; then
        ui_error 'No network. Connect to WiFi in Onion settings, then try again.'
        return 0
    fi

    spin_start '' 'checking'
    if update_check; then
        found=1
    else
        found=0
    fi
    spin_stop

    if [ "$found" -ne 1 ]; then
        ui_error "$UPDATE_ERROR"
        return 0
    fi

    if ! update_is_newer "$UPDATE_VERSION" "$DPADCHAT_VERSION"; then
        ui_info "Up to date (v$DPADCHAT_VERSION)."
        return 0
    fi

    printf '\n'
    ui_info "New version available:"
    ui_info "  v$DPADCHAT_VERSION  ->  v$UPDATE_VERSION"
    printf '\n'

    if ! chat_confirm 'Download and install it?'; then
        ui_info 'Left as it is.'
        return 0
    fi

    spin_start '' 'downloading'
    if update_download_and_stage "$UPDATE_VERSION"; then
        staged=1
    else
        staged=0
    fi
    spin_stop

    if [ "$staged" -ne 1 ]; then
        ui_error "$UPDATE_ERROR"
        ui_info 'Nothing was changed.'
        return 0
    fi

    printf '\n'
    ui_info "v$UPDATE_VERSION is ready to install."
    ui_info 'Quit and reopen D-Pad Chat to finish.'
}

# Removing the app from the device itself, because the alternative is pulling
# the card and finding a computer. Onion's Apps menu is MainUI's, not ours, so
# there is nowhere else to put this: an app cannot add an entry to the menu that
# lists it.
#
# The delete happens in uninstall.sh, from a copy outside the app directory. The
# staging failure paths all end with the install untouched, which is why the
# copy is made before anything is said about deleting.
cmd_uninstall() {
    # A checkout is not an install. Deleting one from inside the app it is
    # running would take the repository's app/ directory with it, and on a dev
    # machine `rm -rf` is never the answer to a question typed at a prompt.
    if ! is_device; then
        ui_info 'Uninstall only runs on the device.'
        ui_info "This copy is a checkout at $APP_DIR"
        return 0
    fi

    printf '\n'
    ui_warn 'Uninstalling deletes this folder:'
    ui_info "  $APP_DIR"
    printf '\n'
    ui_info 'Your API key, this chat and the log go'
    ui_info 'with it. Nothing is kept, and there is'
    ui_info 'no undo.'

    # Only reachable when DPAD_DATA_DIR points somewhere else, which nothing on
    # the device does. Saying so is still cheaper than a user discovering their
    # key is still on the card after being told it was deleted.
    case "$DATA_DIR/" in
        "$APP_DIR"/*) ;;
        *)
            printf '\n'
            ui_warn 'Kept, because it is outside the app:'
            ui_warn "  $DATA_DIR"
            ;;
    esac

    printf '\n'
    if ! chat_confirm 'Uninstall D-Pad Chat?'; then
        ui_info 'Left as it is.'
        return 0
    fi

    # Asked twice on purpose. /update can be undone by updating again; this
    # cannot be undone at all, and the on-screen keyboard makes a stray 'y'
    # easier to press than to mean.
    if ! chat_confirm 'Last chance. Delete it now?'; then
        ui_info 'Left as it is.'
        return 0
    fi

    if ! uninstall_stage; then
        ui_error "$UNINSTALL_ERROR"
        ui_info 'Nothing was changed.'
        return 0
    fi

    log_info 'uninstalling; handing over to the remover'

    # Normally the EXIT trap's job, and `exec` never reaches it — so this is
    # the same pair, in the same order, as on_exit. The terminal state outlives
    # this process either way: the remover reads a key from it, and Onion gets
    # it back afterwards. Raw mode would leave both of them with no echo, and a
    # scroll region would leave Onion scrolling inside rows that are not there.
    #
    # input.sh enters raw mode per line and leaves it on the way out, so this is
    # belt and braces rather than a fix for a state anything reaches today. It
    # costs one call, and the failure it covers is a terminal nobody can type
    # into after the app has deleted itself.
    #
    # The trap is left armed, so an exec that fails still ends the session
    # tidily; both calls are safe to run twice.
    input_restore
    screen_teardown

    printf 'Removing D-Pad Chat...\n'
    uninstall_exec
}

# Reads the answer from the same stdin the REPL uses, so the on-screen keyboard
# works here exactly as it does at the prompt. Anything other than yes is no,
# including EOF: a closed pipe must not be read as consent to overwrite the app.
chat_confirm() {
    printf '\n%s%s [y/N] %s' "$C_USER" "$1" "$C_RESET"

    # The question and the ` [y/N] ` after it are what the answer is typed
    # beside, so together they are this prompt's width.
    if ! input_readline "$((${#1} + 7))"; then
        printf '\n'
        return 1
    fi
    answer="$INPUT_LINE"

    case "$answer" in
        y | Y | yes | Yes | YES) return 0 ;;
        *) return 1 ;;
    esac
}

# Redraw the tail of a resumed conversation. Without this the model would carry
# context the user cannot see, and its replies would refer to things that are
# not on screen.
chat_replay() {
    total=$(history_count)
    [ "$total" -gt 0 ] || return 0

    length=$(history_length)
    shown="$CFG_REPLAY_MESSAGES"
    [ "$shown" -le "$total" ] || shown="$total"

    if [ "$shown" -lt "$total" ]; then
        ui_resume_note "$total messages, showing last $shown"
    else
        ui_resume_note "$total messages"
    fi

    index=$((length - shown))
    while [ "$index" -lt "$length" ]; do
        role=$(history_role "$index")
        content=$(history_content "$index")

        case "$role" in
            user) ui_replay_user "$content" ;;
            assistant) ui_assistant "$content" ;;
        esac

        index=$((index + 1))
    done
}

# Returns 0 when the input was handled as a command, 1 when it is chat text.
dispatch_command() {
    case "$1" in
        # '/?' is quoted: unquoted, the ? is a glob and would swallow every
        # other two-character command.
        /help | /h | '/?')
            cmd_help
            ;;
        # /clear starts a new chat rather than only clearing the screen, which
        # is what it did before conversations persisted. With persistence a
        # blank screen and a blank chat are the same thing to the user, and two
        # commands one letter apart doing different things would be worse.
        /clear | /c | /cls | /new | /reset)
            cmd_new
            ;;
        /about | /version)
            cmd_about
            ;;
        # Matched with a trailing space too, so the name and value come through
        # as part of the line rather than being lost to an exact match.
        /config | /config[[:space:]]* | /set | /set[[:space:]]*)
            cmd_config "$1"
            ;;
        /update | /upgrade)
            cmd_update
            ;;
        # No one- or two-letter form, unlike every other command here. Typing
        # the word out on a d-pad keyboard is the first of the three deliberate
        # acts this needs, and the two confirmations are the others.
        /uninstall | /remove)
            cmd_uninstall
            ;;
        /quit | /exit | /q)
            RUNNING=0
            ;;
        /*)
            ui_error "Unknown command: $1"
            ui_info 'Try /help'
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# Conversation
# -----------------------------------------------------------------------------

# Keep the status field honest about the connection rather than only reporting
# it after something has already failed. net_has_route reads /proc/net/route, so
# this is a file read rather than a probe and is cheap enough to run before every
# prompt; screen_status only repaints when the value actually changed.
chat_refresh_status() {
    if net_has_route; then
        screen_status_from_route 1
    else
        screen_status_from_route 0
    fi
}

# The state bar already carries the name, version and model, so the banner is
# only drawn when there are no bars to carry it.
chat_header() {
    if [ "${SCREEN_BARS:-0}" -ne 1 ]; then
        ui_banner
    fi
}

# A failed request is never fatal: the message is rendered and the REPL carries
# on, because losing the session to a dropped WiFi packet would be worse than
# any error it could report.
chat_respond() {
    if ! history_append user "$1"; then
        ui_error 'Could not record the message.'
        return 0
    fi

    # The indicator runs in the background because the shell blocks inside the
    # streaming pipeline until the first token arrives. It stops itself there,
    # replacing itself with the reply; the calls below cover the paths where no
    # token ever comes.
    #
    # api_send must run in this shell, not a command substitution: its results
    # come back in API_REPLY and API_ERROR, which a subshell would discard.
    if [ "$CFG_STREAM" = 'true' ]; then
        # Opening the line before the indicator starts, not after: the writer is
        # a separate process, and a newline printed underneath it would strand a
        # stale marker on the line above. C_BOT is handed over so the reply
        # keeps its colour once the indicator's own reset has cleared it.
        ui_stream_begin
        spin_start "$C_BOT"

        if api_send_stream "$(history_path)"; then
            spin_stop
            ui_stream_end
            screen_status 'ready'
            _chat_remember "$API_REPLY"
        else
            spin_stop
            ui_stream_end
            _chat_failed
        fi
    else
        spin_start

        if api_send "$(history_path)"; then
            spin_stop
            ui_clear_line
            ui_assistant "$API_REPLY"
            screen_status 'ready'
            _chat_remember "$API_REPLY"
        else
            spin_stop
            ui_clear_line
            _chat_failed
        fi
    fi
}

_chat_remember() {
    history_append assistant "$1"
    history_trim "$CFG_HISTORY_MESSAGES"
}

# Roll back the unanswered question. Leaving it would send it again as context
# next turn, so the model would see a question it never answered and the user
# would watch it steer later replies.
_chat_failed() {
    # curl 6 and 7 are DNS and connect failures, the two that mean the network
    # is gone rather than the request being refused.
    case "${API_TRANSPORT:-0}" in
        6 | 7) screen_status 'offline' ;;
        *) screen_status 'error' ;;
    esac

    ui_error "$API_ERROR"
    history_drop_last
}

# What the first prompt offers, or nothing.
#
# An explicit `suggest` is the user's own words and wins outright. Otherwise
# the game most recently played, if Onion's list names one and there is a
# template to put it in.
#
# There is no way to tell "a game is loaded right now" from "a game was played
# last week": the entry looks the same either way. That would matter a great
# deal if the name were fed to the model silently. It is not - it is ghost text
# that does nothing until Right is pressed - so a stale suggestion costs one
# dismissal, the same as any other suggestion that was not wanted. The
# interaction absorbs the uncertainty, which is why the missing signal never
# had to be found.
chat_opening() {
    if [ -n "$CFG_SUGGEST" ]; then
        printf '%s' "$CFG_SUGGEST"
        return 0
    fi

    [ -n "$CFG_SUGGEST_GAME" ] || return 0

    _co_name=$(game_name) || return 0

    if [ "$CFG_SUGGEST_STRIP_TAGS" = 'true' ]; then
        _co_name=$(game_strip_tags "$_co_name")
    fi
    [ -n "$_co_name" ] || return 0

    # Substituting by parameter expansion rather than sed: the name comes off
    # the card and would otherwise have to be escaped against a regex, and
    # getting that wrong on somebody's ROM title is exactly the sort of failure
    # that never shows up until it does. Only the first placeholder is replaced.
    #
    # The placeholder is held in a variable rather than written into the pattern
    # literally, and that is not style. Written literally, the closing brace of
    # `{game}` is a `}` inside `${...}` - dash and the busybox this is tested
    # against read it as part of the quoted pattern, and Onion's busybox ends
    # the expansion there instead. The prompt on the device came up reading
    # `I'm playing {game} -'*}Pokemon - Emerald Version...`: template
    # unsubstituted, leftover pattern bytes printed, twice over.
    #
    # With the placeholder in a variable the only `}` inside either expansion is
    # the one that closes it, so there is nothing left for a shell to disagree
    # about. Nothing available here reproduces the failure, which is exactly why
    # the form that cannot fail is the one to use.
    _co_ph='{game}'

    case "$CFG_SUGGEST_GAME" in
        *"$_co_ph"*) ;;
        *)
            printf '%s' "$CFG_SUGGEST_GAME"
            return 0
            ;;
    esac

    printf '%s%s%s' \
        "${CFG_SUGGEST_GAME%%"$_co_ph"*}" \
        "$_co_name" \
        "${CFG_SUGGEST_GAME#*"$_co_ph"}"
    return 0
}

repl() {
    RUNNING=1

    # Reaches the first prompt and no further: input_readline consumes it, and
    # nothing sets another. That is the intent rather than a limitation - an
    # opener is for opening, and by the second prompt there is a conversation
    # under way that the same sentence would only interrupt.
    input_suggest "$(chat_opening)"

    while [ "$RUNNING" -eq 1 ]; do
        chat_refresh_status
        printf '\n'
        ui_prompt

        # A failed read means EOF: the pipe closed, or `st` exited via Select.
        if ! input_readline "$UI_PROMPT_COLS"; then
            printf '\n'
            break
        fi
        input="$INPUT_LINE"

        # Trim surrounding whitespace, which the on-screen keyboard makes easy
        # to introduce and which would otherwise defeat command matching.
        input=$(printf '%s' "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        [ -n "$input" ] || continue

        # Recallable with Up from the next prompt. Commands are remembered
        # along with questions: retyping /update on a d-pad is exactly what
        # this is for.
        input_remember "$input"

        if dispatch_command "$input"; then
            continue
        fi

        chat_respond "$input"
    done
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

# The scroll region is global terminal state, so releasing it matters more than
# the log line: without this, Onion gets a terminal that scrolls inside two
# rows that are no longer there.
on_exit() {
    # Before screen_teardown, because a terminal left in raw mode is the worse
    # of the two things to hand back: Onion's menu would come up with no echo.
    input_restore
    screen_teardown
    log_info '--- session ended ---'
}

main() {
    setup_paths
    log_init "$DATA_DIR" || die "Cannot write to data directory: $DATA_DIR"
    trap on_exit EXIT
    trap 'RUNNING=0' INT TERM

    require_cmd fold sed date curl jq mktemp

    config_load "$DATA_DIR"
    history_init "$DATA_DIR" "$CFG_SYSTEM_PROMPT" ||
        die "Cannot write history to $DATA_DIR"
    update_init "$APP_DIR" "$DATA_DIR" "$API_CACERT"
    uninstall_init "$APP_DIR"
    game_init
    api_render_init

    ui_init
    screen_init
    input_init
    chat_refresh_status
    screen_clear
    chat_header

    if [ "$HISTORY_RECOVERED" -eq 1 ]; then
        ui_warn 'The saved chat could not be read; starting a new one.'
    fi

    if [ "$HISTORY_RESUMED" -eq 1 ] && ! history_is_empty; then
        chat_replay
    elif [ "${SCREEN_BARS:-0}" -ne 1 ]; then
        # With the bars up the controls are pinned to the bottom row, so
        # printing them into the transcript as well would just be a repeat.
        ui_hints
    fi

    # Stay in the REPL without a key: /help then explains where to put one,
    # which is more useful than exiting onto a menu with no explanation.
    if ! config_has_key; then
        printf '\n'
        ui_warn 'No API key set - /help explains how.'
    fi

    repl
}

main "$@"
