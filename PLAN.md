# D-Pad Chat — v1 Plan

A ChatGPT client for Onion OS on the Miyoo Mini+, built as a POSIX shell script running
inside Onion's bundled `st` terminal (which supplies the on-screen keyboard for free).

**Target:** Miyoo Mini **Plus** only. The original Miyoo Mini has no WiFi, so it is out of
scope — v1 will detect the absence of a network interface and show a clear message rather
than pretend to work.

> This is the design record: why things are built the way they are, and what was
> deliberately left out. For using the app, see [README.md](README.md),
> [GUIDE.md](GUIDE.md) for installing it, and [COMMANDS.md](COMMANDS.md) for the commands
> and settings.

---

## 1. Why shell + `st`

Everything needed already ships with Onion OS, so v1 requires no cross-compiler:

| Need | Provided by Onion at `/mnt/SDCARD/.tmp_update/` |
|---|---|
| HTTPS requests | `bin/curl`, `lib/libcurl.so.4`, `lib/libssl.so.3` |
| JSON build/parse | `bin/jq` |
| On-screen keyboard | `bin/st` — **X** toggles it show/hide |
| Clock sync (TLS needs it) | `bin/ntpdate` |

The native-SDL route (`lib/libkbinput.so` → `launch_keyboard()`) is deliberately deferred
to v2. It buys a nicer UI at the cost of a Docker toolchain and a build step.

---

## 2. Package layout

Repo (`dpad-chat/`) mirrors what lands on the SD card, so "install" is a folder copy:

```
app/                          ->  /mnt/SDCARD/App/DPadChat/
├── config.json                   Onion app manifest
├── launch.sh                     entry point: applies a staged update, exec st -e chat.sh
├── chat.sh                       main REPL
├── apply-update.sh               copies a staged tree over the app (§9, /update)
├── uninstall.sh                  deletes the app from the card (§9, /uninstall)
├── lib/
│   ├── api.sh                    payload build + curl call + response parse
│   ├── ui.sh                     word wrap, banner, spinner, colors
│   ├── screen.sh                 pinned bars, waiting indicator
│   ├── update.sh                 release check, download, stage
│   └── config.sh                 settings load/save, first-run key entry
├── res/
│   ├── icon.png                  app icon (~200x200, transparent PNG)
│   └── cacert.pem                CA bundle (see §7)
└── data/                         created at runtime, git-ignored
    ├── settings.cfg              API key, model, max_tokens
    ├── history.json              conversation as a JSON array
    └── update/                   staged release, waiting for the next launch
tools/
├── install.sh                    copy app/ to a mounted SD card
├── simulate.sh                   run chat.sh on desktop for testing
└── mockapi.py                    scripted fake OpenAI endpoint (see §10)
Dockerfile                        Alpine test harness
docker-compose.yml                app + mockapi
```

`config.json`, matching the format Onion's own Terminal app uses:

```json
{
  "label": "D-Pad Chat",
  "icon": "res/icon.png",
  "launch": "launch.sh",
  "description": "Chat with GPT over WiFi"
}
```

`launch.sh` wires up Onion's bin/lib paths and hands off to the terminal:

```sh
#!/bin/sh
APPDIR=$(dirname "$0")
sysdir=/mnt/SDCARD/.tmp_update
export PATH="$sysdir/bin:$PATH"
export LD_LIBRARY_PATH="$sysdir/lib:$LD_LIBRARY_PATH"
cd "$sysdir"
HOME=/mnt/SDCARD ./bin/st -e "$APPDIR/chat.sh"
```

---

## 3. Controls

The buttons themselves are inherited from `st`'s keyboard (`keyboard.c`). What the keyboard
*sends* still has to be interpreted, though — see [§5.1](#51-reading-a-line):

| Button | Action |
|---|---|
| **X** | toggle keyboard on/off — the headline feature |
| D-pad | move key cursor |
| **A** | press key |
| **B** | sticky-toggle a key (shift, ctrl) |
| **L1 / R1** | shift / backspace |
| **Y** | move keyboard between top and bottom |
| **Start** | Enter — sends the message |
| **Select** | quit `st`, exits the app |

---

## 4. On-device mockups

Drawn at **40 columns × 30 rows**, the likely grid for `st`'s doubled 8×8 pixel font on a
640×480 panel. This is an estimate — the real count is open question #2 in §11, and every
wrap width below shifts with it. Frames are cropped vertically to the interesting part.

### 4.1 Onion Apps menu

D-Pad Chat is just another entry in the carousel once the folder is on the card:

```
┌────────────────────────────────────────┐
│                                  12:34 │
│                                        │
│     .------.  .========.  .------.     │
│     | [=]  |  || >_   ||  | (o)  |     │
│     '------'  '========'  '------'     │
│                                        │
│     Tweaks     D-Pad Chat    Music     │
│                                        │
└────────────────────────────────────────┘
```

### 4.2 First run — API key entry

Shown once, when `settings.cfg` has no key. Keyboard comes up automatically here:

```
┌────────────────────────────────────────┐
│ D-Pad Chat -- first run                │
│----------------------------------------│
│                                        │
│ Paste your OpenAI API key.             │
│ Press X for the keyboard, Start to     │
│ confirm.                               │
│                                        │
│ key> sk-****************               │
│                                        │
│----------------------------------------│
│  ` 1 2 3 4 5 6 7 8 9 0 - =  BKSP       │
│   q w e r t y u i o p [ ] \            │
│   a s d f g h j k l ; '  ENTER         │
│   z x c v b n m , . /   SHIFT          │
│        [    SPACE    ]                 │
└────────────────────────────────────────┘
```

### 4.3 Launch banner, keyboard hidden

```
┌────────────────────────────────────────┐
│ D-Pad Chat            gpt-4o-mini      │
│----------------------------------------│
│ X keyboard  Start send  Select quit    │
│ /help for commands                     │
│                                        │
│ >                                      │
│                                        │
│                                        │
│                                        │
└────────────────────────────────────────┘
```

### 4.4 Typing — keyboard shown (press X)

The overlay eats the bottom half, leaving ~9 rows of scrollback. This is exactly why the
toggle matters: you type with it up, then hide it to read.

```
┌────────────────────────────────────────┐
│ D-Pad Chat            gpt-4o-mini      │
│----------------------------------------│
│                                        │
│ > what is a miyoo mini                 │
│                                        │
│ It's a small Linux handheld for retro  │
│ games, running a 1.2 GHz ARM chip with │
│ 128 MB of RAM.                         │
│                                        │
│ > how much ram does th                 │
│----------------------------------------│
│  ` 1 2 3 4 5 6 7 8 9 0 - =  BKSP       │
│   q w e r t y u i o p [ ] \            │
│   a s d f g[h]j k l ; '  ENTER         │
│   z x c v b n m , . /   SHIFT          │
│        [    SPACE    ]                 │
└────────────────────────────────────────┘
```

`[h]` marks the D-pad cursor; **A** presses it, **Start** sends the line.

### 4.5 Waiting on a reply

Non-streaming v1 shows a spinner so the device never looks frozen:

```
┌────────────────────────────────────────┐
│ > explain the SSD202D chip             │
│                                        │
│ thinking... (-)                        │
│                                        │
└────────────────────────────────────────┘
```

Once M5 lands, this is replaced by text appearing token by token.

### 4.6 Reading a reply — keyboard hidden (press X again)

Full 30 rows for output, wrapped to the terminal width by `fold -s`:

```
┌────────────────────────────────────────┐
│ D-Pad Chat            gpt-4o-mini      │
│----------------------------------------│
│                                        │
│ > explain the SSD202D chip             │
│                                        │
│ The SigmaStar SSD202D is the system-   │
│ on-chip inside the Miyoo Mini and      │
│ Mini+. It pairs two ARM Cortex-A7      │
│ cores at 1.2 GHz with 128 MB of        │
│ on-package DDR3, which is why the      │
│ handheld tops out around PS1-era       │
│ emulation.                             │
│                                        │
│ >                                      │
│                                        │
│                                        │
└────────────────────────────────────────┘
```

### 4.7 Error state

Every failure in §8 renders in this shape — plain, and it returns you to the prompt
rather than dumping you back to the menu:

```
┌────────────────────────────────────────┐
│ D-Pad Chat                             │
│----------------------------------------│
│                                        │
│  !  No network.                        │
│                                        │
│  Connect to WiFi from Onion's          │
│  settings, then relaunch.              │
│                                        │
│  Select = quit                         │
│                                        │
└────────────────────────────────────────┘
```

---

## 5. Chat loop

```
startup
  ├─ load settings; if no API key -> first-run prompt, save with chmod 600
  ├─ if system year < 2024 -> ntpdate sync (TLS fails on a wrong clock)
  ├─ check network; no interface/route -> friendly error, exit
  └─ print banner + control hints

repl
  ├─ printf "\n> " ; input_readline        (see 5.1)
  ├─ slash commands: /help /clear /model /key /quit
  ├─ append {role:user} to history.json
  ├─ build payload with jq  (never string-interpolate user text)
  ├─ POST api.openai.com/v1/chat/completions
  ├─ print reply word-wrapped to terminal width
  ├─ append {role:assistant} to history.json
  └─ trim history to system + last 10 messages
```

Payload is assembled by `jq` so quotes and newlines in user input can't break the JSON:

```sh
jq -n --arg model "$MODEL" --argjson msgs "$(cat "$HISTORY")" \
      --argjson max "$MAX_TOKENS" \
      '{model:$model, messages:$msgs, max_tokens:$max}'
```

History trimming keeps the system prompt pinned at index 0:

```sh
jq '.[0:1] + (.[1:] | .[-10:])' "$HISTORY"
```

**RAM and screen budget.** 128 MB total and a 640×480 pixel font mean long replies are
painful. v1 ships a system prompt of *"Answer concisely. Stay under 120 words unless the
user asks for detail."* plus `max_tokens: 512`, both overridable in `settings.cfg`.

### 5.1 Reading a line

The prompt originally used the shell's `read` builtin, which leaves the terminal in
**canonical mode**. There the kernel's line discipline owns echo and editing, and it has
two limits that turn out to matter a great deal on a handheld:

- it understands exactly one editing key, ERASE, and rubs a character out with `\b \b`,
  which cannot cross a wrapped row
- it has no notion of escape sequences, so every other key on the keyboard is echoed as
  its raw bytes and appended to the message

That is where four separate device bugs came from — Home, Del and the arrow keys typing
gibberish, and backspace stalling at the wrap point. None of them are fixable while the
kernel is doing the editing, so `app/lib/input.sh` takes the terminal raw (`-icanon
-echo`) and does the work itself: one byte at a time, rendering the line, consuming a
multi-byte key as a single unit, and discarding anything it does not bind.

Keys the editor binds. Anything absent is consumed and discarded, which is the whole
point: a key with no meaning must leave no trace rather than typing its bytes.

| Key | Bytes | Does |
| --- | --- | --- |
| Enter | `CR`, `LF` | submits the line |
| Backspace | `0x7F`, `0x08` | erases the character behind the cursor |
| Del | `ESC [ 3 ~` | erases as well — see below |
| Ctrl-D | `0x04` | ends input, but only on an empty line |

Which byte Backspace sends is a property of how the terminal was built, not of the key,
so both are bound; guessing wrong leaves the key dead. Del means *forward* delete where a
cursor can sit mid-line, but the cursor cannot yet be anywhere but the end of the line,
so there is never a character in front of it — erasing the one behind is what makes the
key useful in the position it is actually pressed in. The forward case arrives with the
cursor movement that makes it reachable.

Notes that are easy to get wrong:

- **Bytes are read with `dd`, not `read -n 1`.** `-n` is a bashism that busybox ash
  supports and dash does not. The suite runs under dash and the device runs busybox, so
  the portable primitive is what keeps the tested code identical to the shipped code.
- **Raw mode is entered per line, not held for the session.** While a reply downloads the
  terminal is in its normal state, so a crash mid-request cannot strand the user with a
  terminal that has no echo. `input_restore` is also wired into the exit trap.
- **Escape sequences need a read timeout.** A lone ESC has no continuation, so the
  follow-up read is given 0.2 s to produce one and then gives up, rather than hanging
  until the next keypress.
- **No terminal means no editor.** Piped input falls back to `read`, which is what the
  test suite and `echo /about | tools/simulate.sh` go through.
- **Erasing across a wrap needs the terminal's width**, and the editor must agree with
  `ui.sh` about what it is, or the two put the wrap in different places. Same sources in
  the same order: `UI_COLS`, then `COLUMNS`, then the terminal. Where no width can be
  established the editor stays on one row rather than moving the cursor somewhere it
  guessed.
- **Filling the last column does not move the cursor to the next row.** The terminal
  leaves the wrap pending and acts on it only when the next character arrives, so at that
  moment the cursor's row is ambiguous — exactly at the boundary the erase arithmetic
  cares about. Inserting forces the wrap there to settle it.

Testing it needs a real pty, since raw mode and echo do not exist without one.
`tests/keys.py` supplies one, and avoids the usual race — a pty starts with echo on, so
anything written before the program takes the terminal raw is echoed by the kernel and
pollutes the capture — by polling the terminal for ECHO to clear before writing a byte.
That is deterministic where a `sleep` is not, and it doubles as proof that raw mode was
entered at all.

---

## 6. Response rendering

Reply text goes through `fold -s -w "$COLS"` where `COLS` is detected once at startup
(`stty size`, falling back to a constant measured on-device). The keyboard overlay covers
part of the screen when shown, which is exactly why X-to-hide matters for reading.

---

## 7. TLS, and why we don't use `curl -k`

Onion has **no CA bundle** — its own scripts (`ota_update.sh`, the scraper) all call
`curl -k`. That is acceptable for fetching public release metadata. It is not acceptable
here, because every request carries a bearer token; `-k` makes the API key trivially
interceptable on hostile WiFi.

v1 ships `res/cacert.pem` (Mozilla bundle from curl.se) and always passes `--cacert`.
If verification fails, the app reports it and stops rather than silently downgrading.

---

## 8. Error handling

| Condition | Behavior |
|---|---|
| No WiFi / no route | "No network. Connect WiFi in Onion settings first." exit |
| Clock skewed | auto `ntpdate`; if that fails, explain the TLS implication |
| HTTP 401 | "Invalid API key" + offer `/key` to re-enter |
| HTTP 429 / 5xx | show status, retry once with backoff, then return to prompt |
| Malformed JSON | show raw first 200 chars, keep session alive |
| `curl` non-zero | surface exit code and message, never a silent empty reply |

The REPL never dies on a failed request — errors return to the prompt.

---

## 9. Milestones

| # | Deliverable | Done when |
|---|---|---|
| **M0** | Package scaffold + `config.json` + icon | "D-Pad Chat" appears in Onion's Apps menu and launches `st` |
| **M1** | Client, settings, mock server | Done. Single-turn requests; every failure path tested |
| **M2** | Interactive REPL + history + trimming | Done. Multi-turn context, trimming, rollback on failure |
| **M3** | First-run key entry, `settings.cfg`, slash commands | Fresh install is usable with no file editing |
| **M4** | Robustness pass (§8) + clock sync + `--cacert` | Done. Verified TLS with no fallback, route and clock preflight |
| **M5** | Streaming replies | Done. Tokens appear as generated; timing is asserted |
| **M6** | `/update` from GitHub releases | Done. Checks, asks, stages; the swap happens at launch |

Streaming landed last because it was the riskiest piece, and the risk was real: the
device's busybox is 1.20.2 from 2019 and its `sed` has no `-u`, so the planned pipeline
would have block-buffered and defeated the point. The shipped version drops `sed`
entirely — the shell strips the `data: ` prefix itself, and `read` is unbuffered:

```sh
curl -N ... | while IFS= read -r line; do
    case "$line" in
        'data: [DONE]') break ;;
        'data: '*) printf '%s\n' "${line#data: }" ;;
    esac
done | jq -j --unbuffered '.choices[0].delta.content // empty'
```

Still one `jq` process for the whole stream — one per token would crawl on a 1.2 GHz A7 —
and the prefix strip costs no process at all. The device's `jq` is 1.6 and supports
`--unbuffered`.

One trade-off: streamed text is not passed through `fold -s`, because `fold` would buffer
for the same reason `sed` did. The terminal wraps instead, which can split a word. Set
`stream = false` for the buffered path with clean wrapping.

### Why `/update` cannot install itself

The obvious shape — download, unpack over the app directory, tell the user to relaunch —
corrupts the running session. `sh` reads a script incrementally from an open file
descriptor rather than loading it whole, so rewriting `chat.sh` underneath itself makes
the interpreter resume at a byte offset in different content. Overwriting `launch.sh` has
the same problem one level up.

So the work is split at the only safe seam:

```
chat.sh   /update    check, ask, download, unpack into data/update/, write `ready`
                     (nothing outside data/ is touched)
launch.sh next run   sees `ready`, exec's data/update/apply.sh  <- exec, so launch.sh
                     is no longer being read from disk
apply.sh             copies the staged tree over the app, exec's the new launch.sh
```

`apply.sh` runs from a copy inside `data/update/`, which is the one directory the copy
never writes to — `tools/package.py` excludes `data/` from the archive, which is also what
keeps a user's key and transcript through an update.

Three refusals, in the order they can be checked:

- any archive entry outside `App/DPadChat/`, or containing `..`, before unpacking;
- a staged tree missing a file the app sources, before `ready` is written;
- the same check again at apply time, because the card may have been pulled in between.

The `ready` marker is consumed *before* the copy starts. A copy that fails halfway leaves
a broken install that still boots into the old launcher; a marker left in place would
leave the launcher retrying a failing copy forever, and there is no shell on the device to
break that loop with.

### Why `/uninstall` is a command and not a menu entry

Removing the app meant pulling the card and finding a computer, which is a strange amount
of ceremony for a folder — and it leaves an API key in plain text on the card for as long
as the user does not get around to it. The obvious place for the button is Onion's Apps
menu, beside the tile. That is not available: the menu is MainUI's, an app cannot add an
entry to the list that launches it, and patching MainUI to add one would make this app
responsible for a piece of the operating system it does not own.

So it goes where `/update` already is, and takes the same shape for the same reason. The
delete cannot run from the directory being deleted:

```
chat.sh      /uninstall   warn, ask twice, copy uninstall.sh to a tmpfs work dir
                          (nothing is deleted, and every failure ends here)
             exec         <- so no part of the app is executing from the card
uninstall.sh              rm -rf the app directory, report, hold the screen
```

`uninstall.sh` wraps its work in a function that is called on the last line, so the
interpreter has parsed the whole file before the first delete — including the delete of
its own work directory. Nothing is read from disk after that point.

Its guard is the marker set `config.json launch.sh chat.sh lib/common.sh`, plus a minimum
path depth of three. A path that arrives truncated or empty fails both, and `/mnt/SDCARD`
could never satisfy either. The tests assert on directories that are gone and siblings
that are not, because that is the only evidence that means anything about an `rm -rf`.

Off the device the command refuses outright. A checkout is not an install, and a chat
prompt on a machine with a keyboard should not be able to reach `rm -rf` at all.

---

## 10. Testing

**v1 has no compile step.** The scripts call `curl`, `jq` and `st`, all of which already
live on the device. So Docker is not a cross-compiler here — it is a *device-shaped
runtime* that lets us reproduce the Miyoo's constraints on a laptop. The cross-compile
pipeline becomes real at v2 (§13).

Three tiers, fastest first. Most bugs die at L0.

### L0 — desktop, no container (seconds per iteration)

```sh
dash -n app/chat.sh && shellcheck -s sh app/*.sh app/lib/*.sh
DPAD_SIM=1 COLUMNS=40 tools/simulate.sh
```

`DPAD_SIM=1` redirects `/mnt/SDCARD` to a local fixture tree. Catches logic errors, `jq`
filter mistakes, and wrap behavior. No hardware, no container.

### L1 — Docker, device-shaped (the tier worth building)

Base on **Alpine, not Ubuntu**: Alpine ships busybox + musl, which is far closer to the
Miyoo's userland than glibc Ubuntu. Bashisms that Ubuntu's `/bin/sh` silently tolerates
fail here, which is the entire point.

```dockerfile
FROM alpine:3.19
RUN apk add --no-cache jq curl dash shellcheck
COPY app/ /mnt/SDCARD/App/DPadChat/
ENV COLUMNS=40 LINES=30 DPAD_SIM=1
ENTRYPOINT ["/bin/busybox", "ash"]
```

Paired with a **mock API** (`tools/mockapi.py`, a stdlib `http.server`) that returns
canned responses on demand:

```
docker compose up
  ├─ mockapi   :8080   scripted 200 / 401 / 429 / 500 / truncated-JSON / slow-stream
  └─ app               chat.sh with BASE_URL=http://mockapi:8080
```

This is the real payoff. Every row of the §8 error table becomes a deterministic test
instead of something you hope never happens — you cannot ask the live API to return 429
on cue, and you shouldn't burn tokens proving that word wrap works. It also makes the M5
streaming work testable: the mock can dribble SSE chunks with delays.

Caveat: Alpine's busybox and `jq` are *not* the device's builds. L1 raises confidence in
our logic; it cannot answer open questions #3 and #5 in §11. Those need L2.

### L2 — real hardware over SSH

Enable dropbear in Onion's Tweaks, then:

```sh
rsync -av app/ root@<miyoo-ip>:/mnt/SDCARD/App/DPadChat/
ssh root@<miyoo-ip> /mnt/SDCARD/App/DPadChat/chat.sh
```

Running `chat.sh` directly over SSH exercises everything except the `st` keyboard, and
iterates in seconds. Reseat the SD card only for the final check that the app appears in
the menu and the keyboard behaves. Settle §11's open questions here, at M0/M1, before
writing rendering code against a guessed column count.

### What Docker deliberately does *not* do

Emulate the device. There is no Miyoo Mini emulator, and running `st` under QEMU would
mean standing up a framebuffer for a component we did not write and are not changing.
The keyboard is validated on hardware; everything else is validated in the container.

---

## 11. Open questions to settle on-device

1. Does `config.json` accept an icon path **relative to the app folder** (`res/icon.png`),
   or must it point into `/mnt/SDCARD/Icons/` the way built-in apps do?
2. Exact terminal column/row count `st` reports at 640×480 — every mockup in §4 assumes
   40×30, and the wrap width in §6 depends on it.
3. Does busybox `sed` support `-u`, and does the device `jq` support `--unbuffered`?
4. Does `st -e` need an absolute path, and does **Select**-to-quit exit cleanly enough to
   return to the Onion menu without a stuck process?
5. Does the bundled `curl` negotiate TLS 1.3 with `api.openai.com`, and does it honor
   `--cacert` with a current Mozilla bundle?
6. Does `st` honor **DECSTBM** (`ESC [ 2 ; 29 r`)? The two pinned bars depend on it. If the
   region is ignored, both bars scroll away with the transcript and `screen.sh` needs a
   redraw-per-turn fallback instead.
7. Does busybox `sleep` accept a fractional argument? It decides whether the waiting
   indicator animates at 10 fps or counts seconds at 1 fps. `screen.sh` detects this at
   startup and degrades on its own, so this only confirms which of the two is in use.
8. Do `ESC [ 30;43m` (black on yellow) and `ESC [ 30;47m` (black on white) render legibly
   on the panel, and does the terminal clear the background to the end of the row?
9. Does the update hand-off actually complete on hardware? `apply-update.sh` is tested
   directly, but the `exec` chain it sits in — Onion runs `launch.sh`, which `exec`s the
   installer, which `exec`s the new `launch.sh`, which starts `st` — has only been
   exercised where `st` is absent. This is the one part of `/update` that no test covers.
10. Is `/mnt/SDCARD` writable by the launcher at that point in the boot, and does the card
   have room for a second copy of the app (~150 KB) while it is being staged?

### Release process

Every pull request carries exactly one version label — `major`, `minor` or `patch` — and
CI fails without it. On merge, the release workflow bumps `DPADCHAT_VERSION`, tags, and
publishes two archives.

`app/lib/common.sh` is the single source of truth for the version. Tags and releases are
derived from it, not the other way round, so a checkout at any commit reports the same
version the app prints in `/about`.

Two archives because they have two audiences. The `.zip` is what a person downloads and
unpacks on a desktop. The `.tar.gz` is what `/update` fetches: busybox always has `tar`
and `gzip`, while `unzip` is an optional applet that may not be on the device, and finding
that out after the download is too late. Both are byte-reproducible from the same tree.

---

## 12. Security notes

- The API key lives in plaintext on a FAT32 SD card. FAT has no permission bits, so
  `chmod 600` is advisory at best — anyone with the card has the key. This will be stated
  in the README, and `/key` will support clearing it.
- `data/` is git-ignored so a key never reaches the repo.
- Keys are set an OpenAI usage limit, per the README's setup instructions.

---

## 13. Out of scope for v1

Native SDL UI via `libkbinput`, multiple saved chats, image input, alternate providers,
and any support for the non-WiFi original Mini.

Conversation persistence *was* on this list. The reasoning was that resuming a
conversation whose start has scrolled away is more confusing than beginning a new one —
which turned out to be an argument for replaying the recent turns on screen, not for
throwing them away.

### The v2 cross-compile pipeline, for reference

When the native UI happens, the toolchain step appears — with three corrections worth
recording now:

- **SDL 1.2, not SDL2.** Onion's own Makefiles link `-lSDL -lSDL_ttf -lSDL_image
  -lSDL_rotozoom`. There is no SDL2 on this device.
- **Don't build an Ubuntu + ARM-GCC image by hand.** Onion's Makefile uses
  `aemiii91/miyoomini-toolchain:latest`, which already carries the cross-compiler, SDL 1.2,
  libcurl and OpenSSL built for the target.
- **There is no `.onion` package format.** Onion apps are plain folders under
  `/mnt/SDCARD/App/`; a release is just a zip of that folder.

```
aemiii91/miyoomini-toolchain  ->  make (armv7ve, cortex-a7, neon-vfpv4, hard-float)
                              ->  dpadchat binary + libkbinput.so
                              ->  zip the App/DPadChat/ folder
                              ->  unzip to SD card  ->  Miyoo Mini+
```

Even then, the shell version stays as the fallback path and the reference implementation.
