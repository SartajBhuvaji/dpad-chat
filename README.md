<div align="center">

# D-Pad Chat

**A ChatGPT client for the Miyoo Mini Plus, on [Onion OS][onion].**

Type with the D-pad. Replies stream in as they are generated.

[![CI](https://github.com/SartajBhuvaji/dpad-chat/actions/workflows/ci.yml/badge.svg)](https://github.com/SartajBhuvaji/dpad-chat/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/SartajBhuvaji/dpad-chat?color=slateblue)](https://github.com/SartajBhuvaji/dpad-chat/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Install](GUIDE.md) · [Commands](COMMANDS.md) · [Design notes](PLAN.md) · [Releases][releases]

</div>

<!-- SCREENSHOTS — filenames are fixed; drop the images in docs/img/ and uncomment.

<div align="center">
<img src="docs/img/hero.jpg" alt="D-Pad Chat running on a Miyoo Mini Plus" width="640">
</div>

| Ask | Wait | Read |
| --- | --- | --- |
| ![Typing a question with the on-screen keyboard](docs/img/keyboard.png) | ![The waiting indicator counting seconds](docs/img/thinking.png) | ![A streamed reply on screen](docs/img/reply.png) |

-->

---

## What it is

A handheld with no keyboard, 128 MB of RAM and a 640×480 screen, running a chat client
written entirely in POSIX shell.

It runs inside `st`, the terminal Onion already ships, which means the on-screen keyboard
comes for free: **X** raises it, the D-pad moves the cursor, **Start** sends, **X** hides
it again so you can read. No cross-compiler, no new binaries on the card — the app calls
the `curl`, `jq` and `ntpdate` that Onion already has.

- **Streaming replies.** Tokens appear as they are generated, not after a ten-second
  freeze — which on this hardware is the difference between working and hung.
- **Conversations persist.** Close the app and reopen it; the chat resumes and the recent
  turns are redrawn, so the context the model has is the context you can see.
- **Verified TLS, with no fallback.** The app ships its own CA bundle and refuses to send
  your key over a connection it could not verify.
- **Updates itself.** `/update` checks GitHub, asks, and installs on the next launch.
- **Pinned status bars.** Connection state at the top, controls at the bottom, both
  staying put while the conversation scrolls between them.

> **Status: v1 feature-complete.** [PLAN.md](PLAN.md) has the design, the milestone
> history, and what was deliberately left out.

## Requirements

- A **Miyoo Mini Plus**. The original Mini has no WiFi and is not supported.
- **Onion OS 4.x**, which provides `st`, `curl`, `jq` and `ntpdate`.
- WiFi configured in Onion's settings, and an [OpenAI API key][keys].

## Install

Download the zip from [Releases][releases] and unpack it onto the **root** of the SD card,
so the app lands in `/mnt/SDCARD/App/DPadChat/`. Then open **Apps → D-Pad Chat**.

Over SSH instead, which is much faster if you expect to do it more than once:

```sh
make install-key HOST=192.168.1.42     # copy the app, then prompt for the key
```

Already installed? Type `/update` in the app.

**[Full installation guide →](GUIDE.md)** — every route, setting the key, upgrading,
uninstalling, and what to do when one of them does not work.

## Using it

**[Commands and settings →](COMMANDS.md)** — the slash commands, the button map, the
status bar, and every key you can put in `settings.cfg`.

The short version: **X** toggles the keyboard, **Start** sends, `/help` lists the
commands, and `/about` is the first screen to check when something is wrong.

## Security

The API key sits in plain text on a FAT32 card, which carries no permission bits — anyone
with the card can read it. That is the hardware, not the app. **Use a key with a spending
limit set.**

Everything the app controls is held to a stricter line. Onion's own scripts call
`curl -k`; this one ships a CA bundle and verifies every connection, because every request
carries that key. **There is no insecure fallback** — a missing bundle fails the request
rather than downgrading it. The key never reaches the log, never appears in full on screen,
and reaches `curl` through a mode-600 config file rather than the command line where any
other process could read it. `/update` downloads code, so it is held to the same rule
again, and never sends your OpenAI key to GitHub.

All of it is covered by tests. The reasoning is in [PLAN.md §7 and §12](PLAN.md).

## Development

No cross-compiler is needed — it is shell calling binaries the device already has.

```sh
make check         # lint + the full suite, no API key needed, costs nothing
make sim           # run locally, pinned to the device's 40-column terminal
make test-docker   # the same suite under Alpine's busybox ash
```

The suite drives the client against `tools/mockapi.py`, a scriptable stand-in for the API
and for GitHub releases — a live endpoint cannot be asked to return 429 on demand, and
proving that word wrap works should not spend tokens.

The device shell is busybox ash, so the code stays strict POSIX: no arrays, no `[[ ]]`, no
`$'...'`. `make check` runs `dash -n` and `shellcheck -s sh` over every script;
`make test-docker` is the stricter gate, because Alpine's busybox is the closest available
stand-in for the device userland. CI runs both.

More in [GUIDE.md § Building from source](GUIDE.md#building-from-source).

### Layout

```
app/              what gets copied to /mnt/SDCARD/App/DPadChat/
  config.json       Onion app manifest
  launch.sh         entry point; applies a staged update, then starts st
  chat.sh           the REPL
  apply-update.sh   installs a staged update, run by launch.sh before anything else
  lib/              paths, logging, rendering, screen, settings, client, updater
  res/              icon and CA bundle
tests/            smoke, API, preflight, history, streaming, screen and update tests
tools/            lint, simulate, install, mock server, packaging, icon and CA fetchers
```

## Releases

Every pull request carries exactly one version label — `major`, `minor` or `patch` — and
CI fails without it. On merge, the release workflow bumps the version, tags, and publishes
two archives: a `.zip` for installing by hand, and a `.tar.gz` for `/update`. Both hold
the same files; busybox always has `tar` and `gzip`, while `unzip` is an optional applet
that may not be on the device.

`app/lib/common.sh` is the single source of truth for the version. Tags and releases are
derived from it, so a checkout at any commit reports the same version the app prints in
`/about`.

## License

MIT — see [LICENSE](LICENSE). Third-party credits are in
[ATTRIBUTION.md](ATTRIBUTION.md): the icon derives from Icons8 art, and the CA bundle
comes from the curl project.

[onion]: https://github.com/OnionUI/Onion
[releases]: https://github.com/SartajBhuvaji/dpad-chat/releases
[keys]: https://platform.openai.com/api-keys
