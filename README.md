<div align="center">

# D-Pad Chat

**A ChatGPT client for the Miyoo Mini Plus, on [Onion OS][onion].**

Type with the D-pad. Replies stream in as they are generated.

[![CI](https://github.com/SartajBhuvaji/dpad-chat/actions/workflows/ci.yml/badge.svg)](https://github.com/SartajBhuvaji/dpad-chat/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/SartajBhuvaji/dpad-chat?color=slateblue)](https://github.com/SartajBhuvaji/dpad-chat/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**[Install](GUIDE.md)** · **[Commands](COMMANDS.md)** · **[Design notes](PLAN.md)** · **[Releases][releases]**

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

A handheld with no keyboard, 128 MB of RAM and a 640×480 screen, running a chat client
written entirely in POSIX shell. It runs inside `st`, the terminal Onion already ships, so
the on-screen keyboard comes for free — **X** raises it, **Start** sends, **X** hides it
again so you can read.

- **Streaming replies** — tokens appear as they are generated, not after a ten-second
  freeze.
- **Conversations persist** — close the app and reopen it; the chat resumes where you
  left off.
- **Verified TLS, no fallback** — ships its own CA bundle and refuses to send your key
  over a connection it could not verify.
- **Updates itself** — `/update` checks GitHub, asks first, installs on the next launch.
- **Removes itself** — `/uninstall` deletes the app and your key from the card, from the
  device, with no computer involved.
- **No new binaries** — calls the `curl`, `jq` and `ntpdate` Onion already has.

## Requirements

A **Miyoo Mini Plus** running **Onion OS 4.x**, WiFi configured, and an
[OpenAI API key][keys]. The original Mini has no WiFi and is not supported.

## Install

Download the zip from [Releases][releases] and unpack it onto the **root** of the SD card,
so the app lands in `/mnt/SDCARD/App/DPadChat/`. Then open **Apps → D-Pad Chat**.

Already installed? Type `/update`. Done with it? Type `/uninstall`.

**[Every other way to install →](GUIDE.md)**

> [!IMPORTANT]
> Your API key sits in plain text on a FAT32 card, which has no permission bits — anyone
> with the card can read it. **Use a key with a spending limit set.**

## Documentation

| | |
| --- | --- |
| **[GUIDE.md](GUIDE.md)** | installing, setting the key, upgrading, troubleshooting, building |
| **[COMMANDS.md](COMMANDS.md)** | slash commands, controls, status bar, every setting |
| **[PLAN.md](PLAN.md)** | design record — why it is built this way, and what was left out |
| **[ROADMAP.md](ROADMAP.md)** | where it is going, and what has to be found out first |

## License

MIT — see [LICENSE](LICENSE). Credits in [ATTRIBUTION.md](ATTRIBUTION.md).

[onion]: https://github.com/OnionUI/Onion
[releases]: https://github.com/SartajBhuvaji/dpad-chat/releases
[keys]: https://platform.openai.com/api-keys
