# D-Pad Chat

A chat client for [Onion OS](https://github.com/OnionUI/Onion) on the Miyoo Mini+.

Runs inside Onion's bundled `st` terminal, so the on-screen keyboard comes for free:
press **X** to bring it up, type with the D-pad, **Start** to send, **X** again to hide it
and read the reply.

> **Status: milestone M0.** The app installs, appears in the Apps menu, and runs its
> command REPL. Model responses are stubbed — the API client lands in M1. See
> [PLAN.md](PLAN.md) for the full design and milestone breakdown.

## Requirements

- **Miyoo Mini Plus.** The original Miyoo Mini has no WiFi and is not supported.
- **Onion OS 4.x**, which provides `st`, `curl`, `jq` and `ntpdate`.
- A WiFi connection configured in Onion's settings.

## Install

Copy `app/` to `/mnt/SDCARD/App/DPadChat/` on the SD card, or use the installer:

```sh
make install CARD=/media/you/MIYOO
```

If SSH is enabled in Onion's Tweaks, pushing over the network is much faster than
reseating the card:

```sh
make install-ssh HOST=192.168.1.42
```

Then open **Apps → D-Pad Chat**.

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
| `/clear` | clear the screen |
| `/about` | version, terminal width, data directory |
| `/quit` | exit |

## Development

No cross-compiler is needed: the app is POSIX shell calling binaries that already ship
with Onion OS.

```sh
make check    # lint + smoke tests
make sim      # run locally, pinned to the device's 40-column terminal
make test-docker   # same suite under Alpine's busybox ash
```

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
ssh root@<device-ip> /mnt/SDCARD/App/DPadChat/chat.sh
```

This exercises everything except the `st` keyboard, and iterates in seconds. Launch from
the Apps menu for the final check.

## Layout

```
app/            what gets copied to /mnt/SDCARD/App/DPadChat/
  config.json     Onion app manifest
  launch.sh       entry point; starts st with chat.sh inside it
  chat.sh         the REPL
  lib/            shared helpers (paths, logging, rendering)
  res/            icon
tests/          smoke tests
tools/          lint, simulate, install, icon generator
```

## Security

The OpenAI API key will be stored in plain text under `app/data/`, which is git-ignored.
FAT32 carries no permission bits, so anyone with physical access to the SD card can read
it — use a key with a spending limit set. Unlike Onion's own scripts, which call
`curl -k`, this app ships a CA bundle and verifies TLS, because every request carries
that key.

## License

MIT. See [LICENSE](LICENSE).
