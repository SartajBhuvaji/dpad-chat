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

# -----------------------------------------------------------------------------
# Request
# -----------------------------------------------------------------------------

# api_send <prompt>
api_send() {
    API_REPLY=''
    API_ERROR=''

    if ! config_has_key; then
        API_ERROR='No API key set. See /help.'
        return 1
    fi

    _api_workdir || return 1

    if ! _api_build_payload "$1" >"$API_WORK/payload.json"; then
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

# jq builds the JSON so that quotes, newlines and backslashes in user input are
# escaped properly. Interpolating the prompt into a string would let any
# apostrophe corrupt the request.
_api_build_payload() {
    jq -n \
        --arg model "$CFG_MODEL" \
        --arg system "$CFG_SYSTEM_PROMPT" \
        --arg user "$1" \
        --argjson max_tokens "$CFG_MAX_TOKENS" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            messages: [
                { role: "system", content: $system },
                { role: "user", content: $user }
            ]
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
write-out = "%{http_code}"
output = "$API_WORK/body.json"
EOF
}

_api_attempt() {
    _api_write_curl_config

    API_STATUS=''
    log_info "POST $CFG_BASE_URL/chat/completions model=$CFG_MODEL"

    API_STATUS=$(curl --config "$API_WORK/curl.cfg" 2>"$API_WORK/curl.err")
    curl_status=$?

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

    jq -r '.choices[0].message.content // ""' "$API_WORK/body.json" \
        >"$API_WORK/reply.txt" 2>/dev/null

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
