# Commands and settings

Everything you can type, press, or configure.

- [Slash commands](#slash-commands)
- [Controls](#controls)
- [The status bar](#the-status-bar)
- [Settings](#settings)
- [Environment overrides](#environment-overrides)
- [Where things are kept](#where-things-are-kept)

---

## Slash commands

| Command | Aliases | Effect |
| --- | --- | --- |
| `/help` | `/h`, `/?` | list the commands |
| `/clear` | `/c`, `/cls`, `/new`, `/reset` | start a new chat |
| `/about` | `/version` | version, width, model, TLS state, history size |
| `/update` | `/upgrade` | check GitHub for a new release, and offer to install it |
| `/uninstall` | `/remove` | delete the app, and everything it keeps, from the card |
| `/quit` | `/exit`, `/q` | exit to the Apps menu |

Anything else beginning with `/` is reported as unknown rather than sent to the model, so
a mistyped command never turns into a question you pay for.

### `/help`

The command list, plus a reminder that **X** toggles the keyboard. If no API key is set,
it also prints where to put one.

### `/clear`

Starts a new chat. **This is destructive and final.** The screen goes blank and the
conversation is gone — from the screen and from the card. No copy is kept anywhere, and
there is no undo.

Short of `/uninstall`, which removes everything, it is the only way to lose a chat.
Installing, reinstalling and updating all leave the conversation alone.

An empty screen is the confirmation. The app deliberately does not report what it just
discarded, because the first thing in a new chat should not be a note about the old one.

### `/about`

```
version  0.7.0
width    40 cols
host     Miyoo (Onion OS)
model    gpt-4o-mini
key      sk-pro...bXQA
history  6 of 10 msgs
stream   true
tls      verified (147 certs)
net      route ok, clock 2026
data     /mnt/SDCARD/App/DPadChat/data
```

The first screen to check when something is not working:

- **width** — what the terminal actually reports. Everything is wrapped to it.
- **key** — redacted to the first six and last four characters. If it reads `not set`,
  the settings file was not found or the line was not parsed.
- **history** — how much of the conversation is being resent each turn, against the cap.
- **tls** — `verified (N certs)` means the bundled CA store loaded. `MISSING BUNDLE`
  means requests will fail rather than downgrade.
- **net** — whether a default route exists, and what year the clock thinks it is. A year
  before 2024 makes every certificate look expired.

### `/update`

Asks GitHub for the latest release. If it is newer than what you are running:

```
New version available:
  v0.7.0  ->  v0.8.0

Download and install it? [y/N]
```

Nothing is downloaded before you answer. Answering yes unpacks the release beside the app;
the swap happens on the next launch. Quit and reopen to finish.

`/update` is manual — the app never contacts GitHub unless you ask. Full details, and why
it installs at launch rather than immediately, are in
[GUIDE.md](GUIDE.md#route-4--in-app-with-update).

### `/uninstall`

Removes the app from the device. **This is destructive and final**, and it takes the
folder with it: the app, `settings.cfg` with your API key, the conversation, and the log.

```
Uninstalling deletes this folder:
  /mnt/SDCARD/App/DPadChat

Your API key, this chat and the log go
with it. Nothing is kept, and there is
no undo.

Uninstall D-Pad Chat? [y/N]
```

It asks twice. Nothing is deleted before both answers, and the second is asked because
`/update` can be undone by updating again while this cannot be undone at all. There is no
short alias for the same reason: typing ten characters on a d-pad keyboard is the first
of the three deliberate acts this needs.

The delete itself runs from a copy of the uninstaller staged outside the app folder, so
no part of the app is executing from the directory being removed — the same split, in
reverse, that `/update` uses. If the copy cannot be made, nothing is deleted and the app
carries on.

Off the device — under `make sim`, or over SSH from a checkout — the command refuses and
says so. A checkout is not an install, and `rm -rf` is not something a chat prompt should
be able to reach on a machine with a keyboard.

Onion reads the Apps menu at boot, so the tile can outlive the folder until the next
restart. Deleting `App/DPadChat/` from a computer does exactly the same thing, and is
what to fall back on if the card is write-protected.

### `/quit`

Exits to the Apps menu. **Select** does the same thing.

Your conversation is kept. Reopening resumes where you left off and replays the most
recent turns, so the context the model still has is the context you can see.

---

## Controls

All of these come from `st`, Onion's terminal, rather than from this app.

| Button | Action |
| --- | --- |
| **X** | show / hide the keyboard |
| D-pad | move the key cursor |
| **A** | press the selected key |
| **B** | sticky-toggle a key (shift, ctrl) |
| **L1 / R1** | shift / backspace |
| **Y** | move the keyboard between the top and bottom of the screen |
| **Start** | send |
| **Select** | quit |

The keyboard is drawn over the screen, not beside it, and covers roughly the bottom half.
Hide it with **X** to read anything longer than a line or two. **Y** moves it out of the
way without dismissing it, which is useful mid-conversation.

---

## The status bar

Two rows stay put while the conversation scrolls between them.

```
 D-Pad Chat  gpt-4o-mini              ready
 ...
 X keys  Start send  Select quit     /help
```

The right-hand field of the top bar is the state:

| Reads | Means |
| --- | --- |
| `ready` | a default route exists and the last request, if any, succeeded |
| `offline` | no default route — WiFi is down or not configured |
| `error` | the last request failed for a reason other than the network |

`offline` outranks `error`, and a working route does not clear an `error` on its own — the
network being fine is not news when the last thing sent over it came back a failure. It
clears when a request succeeds.

While a request is in flight, a spinner and an elapsed second count appear where the reply
will be. The moment the first token arrives, the reply replaces it.

---

## Settings

`data/settings.cfg` next to the app, as `key = value` lines. Only `api_key` is required;
everything else has a working default.

```ini
api_key = sk-...
model = gpt-4o-mini
max_tokens = 512
timeout = 60
history_messages = 10
replay_messages = 4
stream = true
```

| Key | Default | What it does |
| --- | --- | --- |
| `api_key` | *(none)* | your OpenAI key. Without it the app runs but cannot send |
| `base_url` | `https://api.openai.com/v1` | any OpenAI-compatible endpoint |
| `model` | `gpt-4o-mini` | the model to ask |
| `max_tokens` | `512` | cap on the reply length |
| `system_prompt` | *(see below)* | the instruction sent ahead of every conversation |
| `connect_timeout` | `10` | seconds to wait for the connection |
| `timeout` | `60` | seconds to wait for the whole reply |
| `history_messages` | `10` | messages resent each turn, besides the system prompt |
| `replay_messages` | `4` | messages redrawn on screen when a chat resumes |
| `stream` | `true` | show the reply as it is generated |
| `github_token` | *(none)* | only used by `/update`; see below |

Lines beginning with `#` are comments. Spaces around the `=` are fine. Unknown keys are
logged and ignored rather than failing the launch.

The file is **parsed**, not sourced — every line is matched against the list above, so
nothing written in it is ever executed. That matters because it holds a credential and
sits on a card anyone can edit.

**`system_prompt`** defaults to an instruction to answer concisely, under 120 words,
because a 640×480 panel fits about 25 lines. Replacing it is the single most effective
setting here if the replies are the wrong shape for the screen.

**`history_messages`** is the memory-versus-cost dial. Ten messages is five exchanges.
Raising it buys longer memory at the price of a larger request every single turn.

**`replay_messages`** is only about the screen, not about what the model sees. The default
of two exchanges fits the panel; replaying the full retained history would push the prompt
off the bottom before you had typed anything.

**`stream`** is a real trade, not a preference. `true` shows tokens as they arrive but
lets the terminal wrap, which can split a word across lines. `false` wraps cleanly on word
boundaries, at the cost of a five-to-ten-second freeze with nothing on screen — and the
device gives no other sign that it is working.

**`github_token`** is optional and only touched by `/update`. This repository is public, so
release metadata is served with no credential at all. Set it only if you are running a
fork whose repository is private, or if you hit GitHub's unauthenticated rate limit.

---

## Environment overrides

Set in the environment, these win over the settings file. This is how the test suite
points the app at a mock server without writing a file.

| Variable | Overrides |
| --- | --- |
| `DPAD_API_KEY` | `api_key` |
| `DPAD_BASE_URL` | `base_url` |
| `DPAD_MODEL` | `model` |
| `DPAD_TIMEOUT` | `timeout` |
| `DPAD_HISTORY_MESSAGES` | `history_messages` |
| `DPAD_REPLAY_MESSAGES` | `replay_messages` |
| `DPAD_STREAM` | `stream` |
| `DPAD_GITHUB_TOKEN` | `github_token` |
| `DPAD_DATA_DIR` | where `data/` lives |
| `DPAD_CACERT` | the CA bundle path |

---

## Where things are kept

Everything is under `App/DPadChat/data/` on the card. Nothing is written outside it.

| File | Holds |
| --- | --- |
| `settings.cfg` | your key and any settings you changed |
| `history.json` | the conversation, as a JSON array |
| `dpad-chat.log` | request endpoints, models and HTTP statuses — never the key |
| `dpad-chat.log.1` | the previous log, rotated at 256 KB |
| `update/` | a staged release waiting for the next launch, when one exists |

The log is the right thing to attach to a bug report. It records what was asked of the
API and what came back, and the key redaction is covered by tests.

Deleting `App/DPadChat/` removes the app and all of this with it, which is precisely
what `/uninstall` does from the device.
