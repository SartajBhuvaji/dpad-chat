# D-Pad Chat

A chat client for [Onion OS](https://github.com/OnionUI/Onion) on the Miyoo Mini+.

Runs inside Onion's bundled `st` terminal, so the on-screen keyboard comes for free:
press **X** to bring it up, type with the D-pad, **Start** to send, **X** again to hide it
and read the reply.

> **Status: milestone M2.** The app installs, appears in the Apps menu, and holds a
> multi-turn conversation over verified TLS. On-device key entry arrives in M3 and
> streaming in M5. See [PLAN.md](PLAN.md) for the full breakdown.

## Requirements

- **Miyoo Mini Plus.** The original Miyoo Mini has no WiFi and is not supported.
- **Onion OS 4.x**, which provides `st`, `curl`, `jq` and `ntpdate`.
- A WiFi connection configured in Onion's settings.

## Install

Download the zip from [Releases](https://github.com/SartajBhuvaji/dpad-chat/releases) and
unpack it onto the root of the SD card, so the app lands in
`/mnt/SDCARD/App/DPadChat/`.

To install from a checkout instead, copy `app/` to `/mnt/SDCARD/App/DPadChat/`, or use
the installer:

```sh
make install CARD=/media/you/MIYOO
```

### Over SSH

Usually the easiest route, and much faster than reseating the card. Enable SSH first
under **Tweaks → Network → SSH**.

```sh
make install-ssh HOST=192.168.1.42              # app only
make install-key HOST=192.168.1.42              # app, then prompt for the API key
```

The login is the **device's**, not your machine's and not WiFi: Onion's default is
`onion` / `onion`. Override with `USER=` if you have changed it. You are asked for the
password once — the connection is multiplexed, so the copy and the key write share it.

`install-key` prompts with the input hidden and sends the key over stdin, so it never
appears in your shell history, in `ps`, or in the device's process list. Settings already
on the device are preserved: only `api_key` is rewritten, so a model or timeout you chose
there survives a reinstall.

For scripted use, `tools/install.sh --ssh <host> --key-file <path>` reads the key from a
file instead of prompting.

Then open **Apps → D-Pad Chat**.

## Configuration

Settings live in `data/settings.cfg` next to the app, as `key=value` lines. Only
`api_key` is required:

```ini
api_key = <paste your key here>
model = gpt-4o-mini
max_tokens = 512
timeout = 60
history_messages = 10
```

`history_messages` caps how much of the conversation is resent each turn — ten messages
is five exchanges. Raising it buys longer memory at the cost of a larger request every
turn; the conversation is not persisted across launches.

`make install-key` writes this for you. Until M3 adds on-device entry, the alternative is
to edit the file on the card by hand. Either way it is parsed against a whitelist of known
keys rather than sourced, so nothing written in it is ever executed.

FTP is available on Onion (`bftpd`, under Tweaks) but is a poor fit here: it sends the
login *and* the key in cleartext over the network, which undoes the point of verifying
TLS on every request. SSH is already set up and costs one password prompt.

Every setting can be overridden by an environment variable (`DPAD_API_KEY`,
`DPAD_MODEL`, `DPAD_BASE_URL`, `DPAD_TIMEOUT`), which is how the test suite points the
app at a mock server.

## Controls

| Button | Action |
| --- | --- |
| **X** | show / hide the keyboard |
| D-pad | move the key cursor |
| **A** | press the selected key |
| **B** | sticky-toggle a key (shift, ctrl) |
| **L1 / R1** | shift / backspace |
| **Y** | move the keyboard between top and bottom |
| **Start** | send |
| **Select** | quit |

All of these come from `st` itself.

## Commands

| Command | Effect |
| --- | --- |
| `/help` | list commands |
| `/new` | start a new conversation |
| `/clear` | clear the screen |
| `/about` | version, width, model, TLS state, history size |
| `/quit` | exit |

## Development

No cross-compiler is needed: the app is POSIX shell calling binaries that already ship
with Onion OS.

```sh
make check         # lint + both test suites
make sim           # run locally, pinned to the device's 40-column terminal
make test-docker   # same suite under Alpine's busybox ash
make mock          # run the mock API on :8080 to poke at by hand
make cacert        # refresh the bundled CA certificates
make package       # build the release archive
```

`tests/api.sh` drives the client against `tools/mockapi.py`, a scriptable stand-in for
the real endpoint. **No API key is needed to run the suite, and it costs nothing** — a
live endpoint cannot be asked to return 429 on demand, and proving that word wrap works
should not spend tokens. Scenarios are chosen by the prompt:

```
scenario:unauthorized
```

Available: `ok`, `long`, `multiline`, `unauthorized`, `rate_limit`, `rate_limit_always`,
`server_error`, `malformed`, `empty`, `slow`, `echo_payload`.

`make check` runs `dash -n` and `shellcheck -s sh` over every script. The device shell is
busybox ash, so the code stays strict POSIX — no arrays, no `[[ ]]`, no `$'...'`.
`make test-docker` is the stricter gate, because Alpine's busybox is the closest
available stand-in for the device userland.

The launcher icon is generated rather than hand-drawn, so it is reviewable as source:

```sh
make icon
```

CI runs the suite under both dash and busybox, and verifies the committed icon still
matches its generator.

### Testing on hardware

Enable SSH in Onion's Tweaks, then run the app directly over the network:

```sh
make install-ssh HOST=<device-ip>
ssh -t onion@<device-ip> /mnt/SDCARD/App/DPadChat/chat.sh
```

This exercises everything except the `st` keyboard, and iterates in seconds. Launch from
the Apps menu for the final check.

## Layout

```
app/            what gets copied to /mnt/SDCARD/App/DPadChat/
  config.json     Onion app manifest
  launch.sh       entry point; starts st with chat.sh inside it
  chat.sh         the REPL
  lib/            shared helpers: paths, logging, rendering, settings, client
  res/            icon and CA bundle
tests/          smoke, API, preflight, and history tests
tools/          lint, simulate, install, mock server, icon and CA fetchers
```

## Security

The API key is stored in plain text under `app/data/`, which is git-ignored.
FAT32 carries no permission bits, so anyone with physical access to the SD card can read
it — use a key with a spending limit set. Unlike Onion's own scripts, which call
`curl -k`, this app ships its own CA bundle and verifies TLS, because every request
carries that key.

**There is no insecure fallback.** If the bundle is missing, the request fails rather
than downgrading — the app will not send your key over a connection nobody verified.
`/about` reports whether TLS is verified and how many trust anchors are loaded.

The bundle is committed rather than downloaded at install time: the device may have no
working network on first run, and a trust store fetched over an unverified connection
would defeat the point. Refresh it with `make cacert`, which records a checksum that CI
verifies.

The key is never written to the log, never printed in full on screen — `/about` shows it
redacted — and reaches curl through a mode-600 config file rather than the command line,
where any other process could read it. All three are covered by tests.

## Releases

Every pull request carries exactly one label — `major`, `minor` or `patch` — and CI
fails without it. On merge, the release workflow bumps `DPADCHAT_VERSION`, tags, and
publishes an archive that unpacks onto an SD card.

`app/lib/common.sh` is the single source of truth for the version; tags and releases are
derived from it, so a checkout at any commit reports the same version the app prints in
`/about`.

```sh
make version    # what is this checkout
make package    # build the archive locally
```

## License

MIT. See [LICENSE](LICENSE). Third-party credits are in
[ATTRIBUTION.md](ATTRIBUTION.md) — the icon derives from Icons8 art, and the CA bundle
comes from the curl project.
