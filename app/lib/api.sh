#!/bin/sh
# Chat completions client.
#
# api_send() returns 0 and leaves the reply in API_REPLY, or returns non-zero
# and leaves a human-readable message in API_ERROR, so the REPL can render it
# and carry on rather than dying mid-session.
#
# Results come back in variables rather than on stdout deliberately: capturing
# stdout requires a command substitution, which runs in a subshell, and the
# error message set there would never reach the caller.

# API_REPLY and API_ERROR are this module's interface, read by chat.sh after
# sourcing. shellcheck analyses one file at a time and cannot see those uses.
# shellcheck disable=SC2034

# Retried once: these are transient by definition, and a handheld on WiFi sees
# them often enough to be worth one automatic attempt.
API_RETRY_CODES='429 500 502 503 504'
API_RETRY_DELAY=2

# Declared here so that reading them is safe under `set -u` before the first
# request.
API_REPLY=''
API_ERROR=''
API_STATUS=''
API_WORK=''

# curl's exit code from the last attempt, so the caller can tell a dead network
# apart from a rejected request without matching on the error text.
API_TRANSPORT='0'

# Set by chat.sh, which is the only component that knows where the app lives.
API_CACERT="${DPAD_CACERT:-}"

# -----------------------------------------------------------------------------
# Folding a reply down to ASCII
# -----------------------------------------------------------------------------
#
# The panel cannot draw anything outside ASCII. `st` renders a multi-byte
# character as one wrong glyph and then swallows the character after it, so a
# reply saying "Pokémon" arrives on screen as "Pok(C)mon" and "Here's" as
# "HereP s". Models produce curly quotes, em dashes and accents constantly, so
# this is most replies, not an edge case.
#
# Done here in jq rather than downstream in the shell, for one reason that
# decides it: jq works on decoded codepoints. A streamed reply arrives in
# chunks, and a chunk boundary can fall in the middle of a multi-byte
# character - any byte-level filter would have to buffer across chunks and
# reassemble, and would corrupt the split character if it got that wrong.
# By the time jq has parsed the JSON there are no bytes left to split.
#
# Three tiers. Named characters that have a sensible ASCII spelling become it,
# including the ones that need more than one character - AE, ss, "..." - which
# is why this maps each codepoint to a *string* rather than substituting in
# place. Latin-1 accented letters are indexed out of a table, so "café" reads
# "cafe" rather than "caf". Everything else becomes a single "?" per character,
# so a line of Japanese is visibly missing rather than silently empty.
#
# `try ... catch .` is the safety net. If a jq on some device lacks something
# used here, the reply comes through exactly as it does today - wrong glyphs -
# rather than coming through empty, which is the one outcome worse than the
# bug this fixes.
#
# One long single-quoted string, so nothing in it is at the mercy of the shell.
# The apostrophes are written as \u0027 for the same reason - spelling them
# literally would mean closing and reopening the quoting three times, and the
# result is unreadable. $c and $m are jq's variables and are meant to stay
# unexpanded, which is what the disable below is for.
# shellcheck disable=SC2016
API_JQ_ASCII='
def ascii:
  def named: {
    "160":" ","162":"c","163":"GBP","165":"JPY","169":"(c)","171":"\"",
    "174":"(r)","176":"deg","183":"*","187":"\"","198":"AE","215":"x",
    "222":"Th","223":"ss","230":"ae","247":"/","254":"th",
    "338":"OE","339":"oe",
    "8194":" ","8195":" ","8199":" ","8201":" ","8202":" ","8208":"-",
    "8209":"-","8211":"-","8212":"-",
    "8216":"\u0027","8217":"\u0027","8218":"\u0027","8242":"\u0027",
    "8220":"\"","8221":"\"","8222":"\"","8243":"\"","8226":"*",
    "8230":"...","8239":" ","8249":"<",
    "8250":">","8364":"EUR","8482":"(tm)","8592":"<-","8594":"->",
    "8722":"-","8734":"inf","8800":"!=","8804":"<=","8805":">="
  };
  def latin1:
    "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty";
  try (
    explode
    | map(
        . as $c
        | (named[$c | tostring]) as $m
        | if $m then $m
          elif $c == 9 or $c == 10 or ($c >= 32 and $c <= 126) then ([$c] | implode)
          elif $c >= 192 and $c <= 255 then latin1[$c - 192 : $c - 191]
          else "?"
          end)
    | join("")
  ) catch .;
'

# -----------------------------------------------------------------------------
# Request
# -----------------------------------------------------------------------------

# api_send <messages-file>
_api_preflight() {
    if ! config_has_key; then
        API_ERROR='No API key set. See /help.'
        return 1
    fi

    if ! api_tls_ready; then
        API_ERROR="Missing CA bundle at $API_CACERT. Reinstall the app; refusing to send the key unverified."
        return 1
    fi

    if ! net_preflight "$CFG_BASE_URL"; then
        API_ERROR="$NET_ERROR"
        return 1
    fi

    _api_workdir
}

api_send() {
    API_REPLY=''
    API_ERROR=''

    if ! _api_preflight; then
        return 1
    fi

    if ! _api_build_payload false "$1" >"$API_WORK/payload.json"; then
        API_ERROR='Could not build the request.'
        _api_cleanup
        return 1
    fi

    # Callers run under `set -e`, where a bare `_api_attempt` returning non-zero
    # would kill the whole session. Every call that can fail stays inside an
    # `if`, which suspends errexit for its condition.
    if _api_attempt; then
        result=0
    else
        result=1
    fi

    if [ "$result" -ne 0 ] && _api_is_retryable "$API_STATUS"; then
        log_info "retrying after HTTP $API_STATUS"
        sleep "$API_RETRY_DELAY"
        if _api_attempt; then
            result=0
        else
            result=1
        fi
    fi

    if [ "$result" -eq 0 ]; then
        API_REPLY=$(cat "$API_WORK/reply.txt")
    fi

    _api_cleanup
    return "$result"
}

# api_send_stream <messages-file>
#
# Same contract as api_send, except the reply is written to stdout as it
# arrives. API_REPLY still holds the whole text afterwards, for the transcript.
api_send_stream() {
    API_REPLY=''
    API_ERROR=''

    if ! _api_preflight; then
        return 1
    fi

    if ! _api_build_payload true "$1" >"$API_WORK/payload.json"; then
        API_ERROR='Could not build the request.'
        _api_cleanup
        return 1
    fi

    if _api_attempt_stream; then
        result=0
    else
        result=1
    fi

    # Retrying after tokens have already been printed would repeat half a reply
    # on screen, so a retry is only safe when nothing was emitted.
    if [ "$result" -ne 0 ] && [ ! -s "$API_WORK/reply.txt" ] &&
        _api_is_retryable "$API_STATUS"; then
        log_info "retrying stream after HTTP $API_STATUS"
        sleep "$API_RETRY_DELAY"
        if _api_attempt_stream; then
            result=0
        else
            result=1
        fi
    fi

    if [ "$result" -eq 0 ]; then
        API_REPLY=$(cat "$API_WORK/reply.txt")
    fi

    _api_cleanup
    return "$result"
}

_api_attempt_stream() {
    _api_write_curl_config stream

    API_STATUS=''
    : >"$API_WORK/reply.txt"
    : >"$API_WORK/other.txt"
    rm -f "$API_WORK/headers"

    log_info "POST (stream) $CFG_BASE_URL/chat/completions model=$CFG_MODEL"

    # curl's exit code has to travel through a file: POSIX sh has no
    # PIPESTATUS, and the pipeline's status is jq's.
    {
        curl --config "$API_WORK/curl.cfg" 2>"$API_WORK/curl.err"
        printf '%s' "$?" >"$API_WORK/curl.rc"
    } | _api_sse_filter |
        jq -j --unbuffered "$API_JQ_ASCII"' .choices[0].delta.content // empty | ascii' \
            2>/dev/null | tee "$API_WORK/reply.txt"

    curl_status=$(cat "$API_WORK/curl.rc" 2>/dev/null || printf '1')
    API_TRANSPORT="$curl_status"
    API_STATUS=$(_api_status_from_headers)

    if [ "$curl_status" -ne 0 ]; then
        API_ERROR=$(_api_transport_error "$curl_status")
        log_error "curl exit $curl_status: $(cat "$API_WORK/curl.err" 2>/dev/null)"
        return 1
    fi

    if [ "$API_STATUS" != '200' ]; then
        # An error arrives as a plain JSON body rather than as SSE, so the
        # filter set it aside instead of printing it as if it were a reply.
        cp "$API_WORK/other.txt" "$API_WORK/body.json" 2>/dev/null || :
        _api_handle_response
        return 1
    fi

    if [ ! -s "$API_WORK/reply.txt" ]; then
        API_ERROR='The model returned an empty reply.'
        return 1
    fi

    return 0
}

# Turns an SSE stream into one JSON object per line. Written as a shell loop
# rather than sed: the device's busybox sed has no -u, so it block-buffers and
# the tokens would arrive in chunks instead of as they are generated. `read` is
# unbuffered, and this costs no process per token.
_api_sse_filter() {
    first=1
    while IFS= read -r line; do
        case "$line" in
            'data: [DONE]')
                break
                ;;
            'data: '*)
                # Hand the screen over to the reply as the first token arrives:
                # stop the waiting indicator, then erase the line it was on.
                #
                # This runs in the pipeline's subshell, so the write has to go
                # to stderr or it would be parsed as JSON by jq downstream.
                # spin_stop is looked up rather than called directly because
                # the tests source this file without screen.sh.
                if [ "$first" -eq 1 ]; then
                    if command -v spin_stop >/dev/null 2>&1; then
                        spin_stop
                    fi
                    printf '\r\033[K' >&2
                    first=0
                fi
                printf '%s\n' "${line#data: }"
                ;;
            '')
                # SSE separates events with blank lines.
                ;;
            *)
                printf '%s\n' "$line" >>"$API_WORK/other.txt"
                ;;
        esac
    done
}

_api_status_from_headers() {
    [ -f "$API_WORK/headers" ] || {
        printf '000'
        return 0
    }
    # A redirect or a proxy can produce several status lines; the last one is
    # the response actually being read.
    grep '^HTTP/' "$API_WORK/headers" 2>/dev/null |
        tail -n 1 | cut -d' ' -f2 | tr -d '\r' ||
        printf '000'
}

_api_workdir() {
    API_WORK=$(mktemp -d 2>/dev/null || mktemp -d -t dpad) || {
        API_ERROR='Could not create a temporary directory.'
        return 1
    }
    # The curl config file below carries the API key.
    chmod 700 "$API_WORK" 2>/dev/null || :
}

_api_cleanup() {
    if [ -n "${API_WORK:-}" ]; then
        rm -rf "$API_WORK"
    fi
    API_WORK=''
}

# The messages array is read from the transcript rather than assembled here, so
# the request carries the whole conversation. jq does the escaping, so quotes
# and newlines anywhere in the history cannot corrupt the request.
_api_build_payload() {
    jq -n \
        --arg model "$CFG_MODEL" \
        --argjson max_tokens "$CFG_MAX_TOKENS" \
        --argjson stream "${1:-false}" \
        --slurpfile messages "$2" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            stream: $stream,
            messages: $messages[0]
        }'
}

# The key goes in a curl config file rather than on the command line, where it
# would be visible to any other process reading /proc or `ps`.
_api_write_curl_config() {
    umask 077
    cat >"$API_WORK/curl.cfg" <<EOF
url = "$CFG_BASE_URL/chat/completions"
header = "Authorization: Bearer $CFG_API_KEY"
header = "Content-Type: application/json"
data-binary = "@$API_WORK/payload.json"
request = "POST"
silent
show-error
connect-timeout = $CFG_CONNECT_TIMEOUT
max-time = $CFG_TIMEOUT
EOF

    if [ "${1:-}" = 'stream' ]; then
        # write-out would append the status code to the body, which in a stream
        # means appending it to the reply. The status comes from the dumped
        # headers instead, and no-buffer keeps curl from holding tokens back.
        cat >>"$API_WORK/curl.cfg" <<EOF
no-buffer
dump-header = "$API_WORK/headers"
EOF
    else
        cat >>"$API_WORK/curl.cfg" <<EOF
write-out = "%{http_code}"
output = "$API_WORK/body.json"
EOF
    fi

    _api_append_tls_config
}

# Onion ships no CA store, which is why its own scripts use `curl -k`. That is
# fine for public release metadata and not fine here, so the app carries its own
# bundle and points curl at it explicitly.
#
# There is deliberately no insecure fallback. If the bundle is missing, the
# request fails rather than sending the key over a connection nobody verified.
_api_append_tls_config() {
    case "$CFG_BASE_URL" in
        https://*) ;;
        *) return 0 ;;
    esac

    cat >>"$API_WORK/curl.cfg" <<EOF
cacert = "$API_CACERT"
proto = "=https"
tlsv1.2
EOF
}

# api_tls_ready
#
# Checked once at startup rather than per request, so a missing bundle is
# reported before the user has typed anything.
api_tls_ready() {
    case "$CFG_BASE_URL" in
        https://*) ;;
        *) return 0 ;;
    esac

    [ -r "$API_CACERT" ]
}

_api_attempt() {
    _api_write_curl_config

    API_STATUS=''
    log_info "POST $CFG_BASE_URL/chat/completions model=$CFG_MODEL"

    API_STATUS=$(curl --config "$API_WORK/curl.cfg" 2>"$API_WORK/curl.err")
    curl_status=$?
    API_TRANSPORT="$curl_status"

    if [ "$curl_status" -ne 0 ]; then
        API_ERROR=$(_api_transport_error "$curl_status")
        log_error "curl exit $curl_status: $(cat "$API_WORK/curl.err" 2>/dev/null)"
        return 1
    fi

    _api_handle_response
}

# -----------------------------------------------------------------------------
# Responses
# -----------------------------------------------------------------------------

_api_handle_response() {
    log_info "HTTP $API_STATUS"

    case "$API_STATUS" in
        200)
            if _api_extract_reply; then
                return 0
            fi
            return 1
            ;;
        401 | 403)
            API_ERROR="Invalid API key. $(_api_error_detail)"
            ;;
        404)
            API_ERROR="Not found: check base_url and model. $(_api_error_detail)"
            ;;
        429)
            API_ERROR="Rate limited. $(_api_error_detail)"
            ;;
        5??)
            API_ERROR="Server error $API_STATUS. $(_api_error_detail)"
            ;;
        *)
            API_ERROR="Unexpected response $API_STATUS. $(_api_error_detail)"
            ;;
    esac

    return 1
}

_api_extract_reply() {
    if ! jq -e . "$API_WORK/body.json" >/dev/null 2>&1; then
        API_ERROR="The reply was not valid JSON: $(_api_body_excerpt)"
        return 1
    fi

    jq -r "$API_JQ_ASCII"' .choices[0].message.content // "" | ascii' \
        "$API_WORK/body.json" >"$API_WORK/reply.txt" 2>/dev/null

    # jq terminates its output with a newline even for an empty string, so the
    # file is never zero bytes. Testing the size here would let a blank reply
    # through and render as silence.
    if [ -z "$(tr -d '[:space:]' <"$API_WORK/reply.txt")" ]; then
        # A 200 with no content usually means the reply was filtered or the
        # response shape changed; either way there is nothing to render.
        API_ERROR="The model returned an empty reply. $(_api_finish_reason)"
        return 1
    fi

    return 0
}

_api_error_detail() {
    jq -r '.error.message // empty' "$API_WORK/body.json" 2>/dev/null ||
        _api_body_excerpt
}

_api_finish_reason() {
    reason=$(jq -r '.choices[0].finish_reason // empty' "$API_WORK/body.json" 2>/dev/null)
    [ -z "$reason" ] || printf '(finish_reason: %s)' "$reason"
}

# Enough of the body to debug with, but bounded: a stray HTML error page from a
# captive portal would otherwise fill the screen.
_api_body_excerpt() {
    head -c 200 "$API_WORK/body.json" 2>/dev/null | tr '\n' ' '
}

# -----------------------------------------------------------------------------
# Transport
# -----------------------------------------------------------------------------

# curl's exit codes are more useful than its stderr on a small screen, so they
# are translated into something a user can act on.
_api_transport_error() {
    case "$1" in
        6) printf 'Could not resolve the server. Check WiFi and DNS.' ;;
        7) printf 'Could not connect. Check WiFi.' ;;
        28) printf 'Timed out after %ss.' "$CFG_TIMEOUT" ;;
        35 | 60) printf 'TLS failed. Check the system clock and CA bundle.' ;;
        *) printf 'Network error (curl %s).' "$1" ;;
    esac
}

_api_is_retryable() {
    for code in $API_RETRY_CODES; do
        if [ "$1" = "$code" ]; then
            return 0
        fi
    done
    return 1
}
