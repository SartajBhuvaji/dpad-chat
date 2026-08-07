# Device-shaped test harness.
#
# Alpine, not Ubuntu: the Miyoo Mini+ runs a busybox userland, and bashisms
# that Ubuntu's /bin/sh tolerates fail here the same way they fail on hardware.
# This image does not cross-compile anything. Milestone M0 through M4 are shell
# scripts calling binaries that already ship with Onion OS; the cross-compiler
# only becomes relevant for the native UI in v2.

FROM alpine:3.19

# jq and curl are the runtime dependencies the app will use from M1 onward.
# dash and shellcheck back tools/lint.sh.
RUN apk add --no-cache \
    curl \
    jq \
    dash \
    shellcheck \
    python3

WORKDIR /src

# Match the device, and writable state outside the tree. 53 columns is what
# /about reports on hardware; it was 40 here on an estimate that turned out to
# be 13 columns narrow, so every wrap the suite exercised fell in the wrong
# place for the screen it is meant to stand in for.
ENV COLUMNS=53 \
    LINES=30 \
    DPAD_DATA_DIR=/tmp/dpad-chat

COPY . /src

ENTRYPOINT ["/bin/busybox", "ash"]
CMD ["-c", "tools/lint.sh && tests/smoke.sh && tests/api.sh && tests/net.sh && tests/history.sh && tests/release.sh && tests/install.sh && tests/stream.sh && tests/screen.sh && tests/input.sh && tests/update.sh && tests/uninstall.sh"]
