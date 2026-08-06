#!/bin/sh
# Preflight checks: is there a network, and is the clock plausible.
#
# Both failures produce confusing symptoms if left to surface inside curl. No
# route looks like a hang followed by a timeout; a wrong clock looks like a
# certificate error, which reads as a security problem rather than as the
# missing RTC battery it actually is.

# NET_ERROR is this module's interface, read by api.sh after sourcing. Static
# analysis works one file at a time and cannot see that use.
# shellcheck disable=SC2034

# Overridable so the tests can point at fixtures instead of the live system.
NET_ROUTE_FILE="${DPAD_ROUTE_FILE:-/proc/net/route}"

# TLS validity windows make any year before this impossible for a certificate
# issued today, so a clock reading earlier than this is certainly unset. These
# handhelds have no RTC battery and boot at the epoch or at a factory date.
CLOCK_FLOOR_YEAR=2024

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

# A default route is the cheapest reliable signal: it means an interface is up
# and configured, which is what the request needs. Reading the kernel table
# directly avoids depending on ip, route or ifconfig being present.
net_has_route() {
    [ -r "$NET_ROUTE_FILE" ] || return 1

    # Fields: Iface Destination Gateway ... A destination of 00000000 is the
    # default route. The header line never matches, so it needs no skipping.
    while read -r iface destination _; do
        if [ "$destination" = '00000000' ] && [ "$iface" != 'lo' ]; then
            return 0
        fi
    done <"$NET_ROUTE_FILE"

    return 1
}

# -----------------------------------------------------------------------------
# Clock
# -----------------------------------------------------------------------------

clock_year() {
    date '+%Y'
}

clock_is_plausible() {
    year=$(clock_year)
    case "$year" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$year" -ge "$CLOCK_FLOOR_YEAR" ]
}

# Onion bundles ntpdate. Failure is not fatal here: the clock may already be
# close enough, and the TLS error that follows explains itself.
clock_sync() {
    command -v ntpdate >/dev/null 2>&1 || return 1

    for server in pool.ntp.org time.cloudflare.com; do
        log_info "syncing clock from $server"
        if ntpdate -s -t 5 "$server" >/dev/null 2>&1; then
            log_info "clock synced, year is now $(clock_year)"
            return 0
        fi
    done

    log_warn 'clock sync failed'
    return 1
}

# -----------------------------------------------------------------------------
# Combined
# -----------------------------------------------------------------------------

# net_preflight <base-url>
#
# Returns 0 when a request has a reasonable chance of succeeding. On failure,
# NET_ERROR holds a message worth showing. Skips the checks entirely for a
# loopback URL, which is how the test suite reaches its mock server.
NET_ERROR=''

net_preflight() {
    NET_ERROR=''

    case "$1" in
        http://127.0.0.1* | http://localhost*) return 0 ;;
    esac

    if ! net_has_route; then
        NET_ERROR='No network. Connect to WiFi in Onion settings, then relaunch.'
        return 1
    fi

    if ! clock_is_plausible; then
        log_warn "clock reads $(clock_year); attempting sync"
        if ! clock_sync && ! clock_is_plausible; then
            NET_ERROR="The clock is wrong (year $(clock_year)), so TLS cannot be verified. Set the time in Onion settings."
            return 1
        fi
    fi

    return 0
}
