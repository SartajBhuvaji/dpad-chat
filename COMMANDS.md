# Commands and settings

Everything you can type, press, or configure.

- [Slash commands](#slash-commands)
- [Controls](#controls)
- [Editing what you type](#editing-what-you-type)
- [Suggested openings](#suggested-openings)
- [What replies look like](#what-replies-look-like)
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
| `/config` | `/set` | change a setting from the device |
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
version  0.9.0
width    53 cols
height   30 rows
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

### `/config`

Changes the settings worth changing without a computer. `/config` on its own lists them:

```
model              gpt-4o-mini
max_tokens         512
history_messages   10
stream             true
suggest_strip_tags true
api_key            sk-pro...bXQA

/config <name>          next value
/config <name> <value>  set it
```

**`/config <name>` moves to the next value** and is the way you are meant to use it — a
character costs several button presses, so a setting you can change without typing one is
worth more than a setting you can type exactly. The cycles are:

| Setting | Cycles through |
| --- | --- |
| `model` | `gpt-4o-mini` → `gpt-4o` → `gpt-4.1-mini` → `gpt-4.1` |
| `max_tokens` | `256` → `512` → `1024` → `2048` |
| `history_messages` | `4` → `10` → `20` → `40` |
| `stream` | `true` → `false` |
| `suggest_strip_tags` | `true` → `false` |

The model list is a cycle order, not a restriction — `/config model whatever-you-like`
sets any name, which is what you want against an OpenAI-compatible endpoint that offers
something else. A value that is not in the list cycles to the first entry.

Changes apply to the conversation you are in **and** are written to `settings.cfg`, so
they survive closing the app. Comments and settings you have hand-edited into that file
are left alone.

**`/config api_key`** asks for the key rather than taking it as an argument, and hides
what you type:

```
> /config api_key

Paste or type the key, then Start.
It is not shown, and not remembered by Up.

 key> *********************
```

That is not decoration. Every line you send is kept for **Up** to recall and stays on
screen above the prompt, so a key given as `/config api_key sk-...` would sit in both.
Asking separately avoids both, and the value is redacted everywhere it is displayed
afterwards.

This is what makes a device with no computer nearby usable from scratch: install the
folder, open the app, `/config api_key`, and you are done.

**Settings not listed here stay in the file.** `base_url` and `github_token` are long and
set once if ever, the timeouts are for debugging, `replay_messages` is cosmetic, and the
`suggest` templates are free text. `/config base_url` says so rather than reporting an
unknown name.

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

## Editing what you type

These are the app's own, not `st`'s, and they work on the line at the prompt.

| Key | Action |
| --- | --- |
| **Left / Right** | move the cursor within the line |
| **Home / End** | jump to the start or end of it |
| **Backspace** | delete the character behind the cursor |
| **Del** | delete the character under the cursor, or behind it at the end of the line |
| **Up / Down** | bring back a line you sent earlier |

Every character costs several button presses here, so being able to reach into the middle
of a line and fix a typo — rather than erasing back to it — is worth more than it is on a
desk keyboard. The same goes for **Up**: it brings back what you sent before, with the
cursor at the end, ready to add to or send again. **Down** walks back towards what you
were typing, which is kept for you while you look.

Backspace and the cursor keys work across a line that has wrapped onto a second row.

What **Up** recalls is only what you typed at this prompt, it lives in memory for as long
as the app is open, and it is not part of the conversation the model sees. `/clear` starts
a new chat but leaves the recall list alone; closing the app empties it.

---

## Suggested openings

Press **Menu** while playing, open D-Pad Chat, and the prompt is already holding this,
greyed out:

```
> I'm playing Road Rash -
```

That text is not in your message. **Right** takes it, leaves a space after it, and puts
the cursor there so you carry straight on typing — *"I'm playing Road Rash - how do I
beat the last race"*. **Any other key** takes it away and is then handled normally, so if
you had something else to ask, just start typing and the suggestion is gone.

Then press **Menu** again and your game is still there, where you left it.

It is offered once, at the first prompt. By the second there is a conversation under way,
and the same sentence again would only be in the way.

Forty characters is around two hundred button presses on a d-pad. Accepting them with one
is the entire point of it.

Nothing is ever sent that you did not either type or accept, which is what makes a
suggestion you did not want cost exactly one keypress.

### Where the game name comes from

Onion keeps a list of what you have opened recently, at `Roms/recentlist.json`. The app
reads the most recent entry that is a game rather than an app, and uses the name Onion
itself displays.

That file is only ever **read**, never written. If a future Onion moves it, renames it or
changes its shape, you lose the suggestion — not the app.

There is no way to tell *"a game is loaded right now"* from *"a game was played last
week"*; the entry looks the same either way. That would matter a great deal if the name
were fed to the model silently. It is not: it is ghost text that does nothing until you
press **Right**, so a stale suggestion costs one keypress, the same as any other
suggestion you did not want.

### Wording it yourself

| Setting | What it does |
| --- | --- |
| `suggest` | a fixed opening. Set it and it wins outright — the game is not consulted |
| `suggest_game` | the template the game's name goes into. Empty turns game awareness off |
| `suggest_strip_tags` | whether `Road Rash (USA, Europe)` becomes `Road Rash` |

```ini
suggest_game = Playing {game}. Keep it short -
```

`{game}` is where the name goes; the first one is replaced. A template with no `{game}` in
it is used as-is whenever a game is found, which is a way to have a fixed opening that
only appears when you have been playing something.

The name must be printable ASCII by the time it reaches the prompt, because the cursor
maths at the prompt counts characters as columns. A title with an accent in it is dropped
rather than mangled, and the prompt comes up plain.

---

## What replies look like

Replies are folded down to ASCII before they reach the screen.

That is not a preference. The panel draws ASCII and nothing else — `st` renders a
multi-byte character as one wrong glyph and then swallows the character after it, so an
unfolded reply arrives as `Pok(C)mon` and `HereP s how`. Models produce curly quotes,
em dashes and accented names constantly, so this is most replies rather than an edge case.

| What the model sends | What you see |
| --- | --- |
| `café`, `naïve`, `Pokémon` | `cafe`, `naive`, `Pokemon` |
| `“quoted”`, `it’s` | `"quoted"`, `it's` |
| `—`, `–`, `…` | `-`, `-`, `...` |
| `Æsop`, `straße` | `AEsop`, `strasse` |
| `5 °C`, `≤`, `→`, `™` | `5 degC`, `<=`, `->`, `(tm)` |
| anything with no ASCII spelling | one `?` per character |

The last row is deliberate: a line of Japanese reads as visibly missing characters rather
than as nothing at all, and one `?` per character rather than per byte.

The same text goes into the transcript, so a resumed conversation redraws what you
actually read rather than the original bytes.

### Bold

Models emit Markdown whatever the system prompt asks for, and on a 53-column screen
`**Rock Smash**` is four characters of noise wrapped around two words. The markers are
turned into the terminal's own bold instead:

| What the model sends | What you see |
| --- | --- |
| `Use **Rock Smash** here` | Use **Rock Smash** here — in bold, no asterisks |
| `2 * 3 = 6`, `* a bullet` | unchanged |

Only `**` is touched. A single `*` is a bullet or a multiplication sign far more often
than it is emphasis.

**With colour off it is left alone.** Under `NO_COLOR`, or when the output is redirected
rather than drawn on a screen, the markers stay as the model wrote them — colour off means
escapes off, not formatting discarded.

The transcript always keeps the reply exactly as the model sent it, Markdown and all. That
file is replayed to the model each turn, so it holds what was said rather than what was
drawn.

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
suggest_game = I'm playing {game} -
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
| `suggest` | *(none)* | a fixed opening offered at the first prompt; see above |
| `suggest_game` | `I'm playing {game} -` | the opening used when a game was just played |
| `suggest_strip_tags` | `true` | drop `(USA, Europe)` and the like from the game's name |
| `github_token` | *(none)* | only used by `/update`; see below |

Six of these can be changed from the device with [`/config`](#config) instead of editing
the file: `model`, `max_tokens`, `history_messages`, `stream`, `suggest_strip_tags` and
`api_key`. The rest are here because they are long, rarely touched, or free text — none of
which suits a d-pad.

Lines beginning with `#` are comments. Spaces around the `=` are fine. Unknown keys are
logged and ignored rather than failing the launch. `/config` preserves all of that when it
writes: comments, spacing and settings it does not know about come back untouched.

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

**`suggest`** must be printable ASCII, and so must the sentence `suggest_game` builds. The
cursor arithmetic at the prompt counts characters as columns, which accented or non-Latin
text breaks, and a control character would be an escape sequence the terminal obeys rather
than text it draws. Anything else is ignored and the prompt comes up plain. Trailing
spaces are trimmed off every value in this file, but you do not need one: accepting a
suggestion adds the space itself.

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
| `DPAD_SUGGEST` | `suggest` |
| `DPAD_SUGGEST_GAME` | `suggest_game` |
| `DPAD_SUGGEST_STRIP_TAGS` | `suggest_strip_tags` |
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
