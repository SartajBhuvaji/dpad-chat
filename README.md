<div align="center">

<img src="docs/img/app.png" alt="The D-Pad Chat tile in Onion's Apps menu" width="640">

**A ChatGPT client for the Miyoo Mini Plus, on [Onion OS][onion].**

[![CI](https://github.com/SartajBhuvaji/dpad-chat/actions/workflows/ci.yml/badge.svg)](https://github.com/SartajBhuvaji/dpad-chat/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/SartajBhuvaji/dpad-chat?color=slateblue)](https://github.com/SartajBhuvaji/dpad-chat/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**[Install](GUIDE.md)** · **[Commands](COMMANDS.md)** · **[Screenshots](SCREENSHOTS.md)** · **[Design notes](PLAN.md)** · **[Releases][releases]**

</div>

<!-- Hero photograph — the device in hand, running a finished conversation.
     Drop it in as docs/img/hero.jpg and uncomment.

<div align="center">
<img src="docs/img/hero.jpg" alt="D-Pad Chat running on a Miyoo Mini Plus" width="640">
</div>

-->

---

The Miyoo Mini Plus is a pocket-sized handheld for emulating classic consoles. It comes
with hundreds of games, and sooner or later you get stuck on one of them. There used to be
a number you could call for that — the Nintendo Power Line. Today the help is a prompt
away, so I built a ChatGPT client that answers on the device itself, without putting it
down to look something up somewhere else.

| Ask | Wait | Read |
| :---: | :---: | :---: |
| <img src="docs/img/question_ask.png" alt="Typing a question with the on-screen keyboard" width="260"> | <img src="docs/img/question_thinking.png" alt="The waiting indicator counting seconds" width="260"> | <img src="docs/img/question_answered.png" alt="A streamed reply on screen" width="260"> |

**[More screenshots →](SCREENSHOTS.md)**

---

It is a handheld with no keyboard, 128 MB of RAM and a 640×480 screen, so the client is
written entirely in POSIX shell. It runs inside `st`, the terminal Onion already ships,
which is where the on-screen keyboard comes from — **X** raises it, **Start** sends, and
**X** hides it again so you can read.

- **Knows what you were playing** — press **Menu** out of a game, open the app, and the
  prompt is already holding *"I'm playing Pokemon - Emerald Version -"* in grey. **Right**
  takes it, any other key takes it away, and **Menu** puts you back in the game where you
  left it. Forty characters is two hundred button presses on a d-pad.
- **Streaming replies** — tokens appear as they are generated, instead of after a
  ten-second freeze.
- **Readable on the panel** — the screen draws ASCII only, so accents and curly quotes are
  folded down rather than left as wrong glyphs, and `**bold**` is rendered rather than
  shown.
- **Conversations persist** — close the app and reopen it, and the chat resumes where you
  left off.
- **Set up on the device** — `/config api_key` takes your key with the input hidden, so a
  card someone hands you works without ever being plugged into a computer.
- **Verified TLS, no fallback** — it ships its own CA bundle, and refuses to send your key
  over a connection it could not verify.
- **Updates itself** — `/update` checks GitHub, asks first, and installs on the next
  launch.
- **Removes itself** — `/uninstall` deletes the app and your key from the card, on the
  device, with no computer involved.
- **No new binaries** — it calls the `curl`, `jq` and `ntpdate` that Onion already has.

## Requirements

A **Miyoo Mini Plus** running **Onion OS 4.x**, with WiFi configured, and an
[OpenAI API key][keys]. The original Mini has no WiFi and is not supported.

## Install

Download the zip from [Releases][releases] and unpack it onto the **root** of the SD card,
so that the app lands in `/mnt/SDCARD/App/DPadChat/`. Then open **Apps → D-Pad Chat**.

Already installed? Type `/update`. Done with it? Type `/uninstall`.

**[Every other way to install →](GUIDE.md)**

> [!IMPORTANT]
> Your API key sits in plain text on a FAT32 card, which has no permission bits — anyone
> who has the card can read it. **Use a key with a spending limit set.**

## Documentation

| | |
| --- | --- |
| **[GUIDE.md](GUIDE.md)** | installing, setting the key, upgrading, troubleshooting, building |
| **[COMMANDS.md](COMMANDS.md)** | slash commands, controls, status bar, every setting |
| **[SCREENSHOTS.md](SCREENSHOTS.md)** | what each screen looks like on the device |
| **[PLAN.md](PLAN.md)** | design record — why it is built this way, and what was left out |
| **[ROADMAP.md](ROADMAP.md)** | where it is going, and what has to be found out first |

## License

MIT — see [LICENSE](LICENSE). Credits in [ATTRIBUTION.md](ATTRIBUTION.md).

[onion]: https://github.com/OnionUI/Onion
[releases]: https://github.com/SartajBhuvaji/dpad-chat/releases
[keys]: https://platform.openai.com/api-keys
