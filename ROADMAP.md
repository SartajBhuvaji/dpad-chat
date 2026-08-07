# Roadmap

`PLAN.md` records what was built and why. This records where it is going, and — more
usefully — what has to be found out before parts of it can be costed at all.

The staging exists so that the expensive work is done last, after the cheap work has
proved it is the right work.

**Chosen: stages A and B.** Onion can already switch from a running game to an App, so the
hard part of getting there mid-game is somebody else's code and already written. A builds
the suggestion mechanism, B makes the suggestion be about the game. Neither needs a
background process, a compiler, or a change to how the app is installed.

Stages C and D stay written down and unstarted. Whether either is worth building is a
question about how B feels in the hand, and that cannot be answered before B exists.

---

## 1. The idea

Ask a question without putting the game down.

You are stuck on a boss. You get to the app, and it is already holding *"I'm playing
Chrono Trigger — "*. You type only the part that is actually your question, read the
answer, and go back to the frame you left.

That is a use case no desktop client has, and it is the reason to run this on a handheld
rather than reach for the phone sitting next to it.

---

## 2. Why this is not one feature

It reads like an extension of the app. It is not, and the reason decides the whole shape
of the work.

Everything built so far runs inside `st`, Onion's terminal. That is what gives us the
on-screen keyboard for free, and it is why a shell script is a viable client at all. It
also rules out three things at once:

- **A terminal cannot be translucent.** It draws opaque character cells. There is no alpha
  anywhere in the model.
- **A terminal cannot appear over a running game.** The emulator owns the framebuffer and
  rewrites it every frame. Anything drawn over it is gone in about sixteen milliseconds.
- **There is no compositor.** The Miyoo has one framebuffer and nothing that stacks
  surfaces onto it. "Windows over other windows" is not a service this system offers.

So a translucent panel over a live game is not a flag we pass to `st`. It is a program
that reads `/dev/fb0`, blends its own pixels with what the game last drew, renders text
with its own font, and reads `/dev/input/event0` itself.

None of that argues against doing it. It argues against starting there — because most of
what makes the idea good needs none of it.

---

## 2a. What none of this may require

Anything that needs the user to modify Onion, enable something, or know what SSH is has
lost most of the people who would otherwise use it. A handheld is not a workstation, and
somebody who has just copied a folder onto a card should not then be asked to earn the
feature. This is a constraint on the design, not a preference about it.

Three rules, and every stage is scored against them:

**1. Installing stays "copy a folder."** Nothing registered, nothing at boot, nothing
patched. Uninstalling stays "delete the folder."

**2. Onion is read-only.** We may read what it leaves lying about. We never write to it,
never patch it, and never require a particular version of it. If a future Onion moves or
renames something we read, we lose a suggestion — not a working app.

**3. Nothing we do may cost the user their game.** This is the one that actually separates
the stages, and it took the constraint being written down to see it.

| | Installs cleanly | Only reads Onion | Cannot harm a game |
| --- | --- | --- | --- |
| **A** — prefill | yes | touches nothing | yes |
| **B** — game-aware | yes | two file reads | yes |
| **C** — chord | via `/background` | yes | **no** — signals a live emulator |
| **D** — overlay | binary in our folder | yes | **no** — writes the framebuffer |

**A and B have no blast radius at all.** The worst failure either can produce is a wrong
suggestion or no suggestion, and §4 makes that failure silent by design.

**C and D reach into a running game** — stopping its process, or drawing over the screen it
owns. If either goes wrong, what is lost is somebody's unsaved progress, which is a far
worse thing to be wrong about than a prompt. That does not rule them out, but it does mean
they need a much higher bar than "it worked when I tried it", and it is a second
independent reason they sit behind B rather than in front of it.

---

## 3. Stage A — the prefill, in the terminal we already have

**Ships inside the current app. No new binary, no new process.**

Ghost text at the prompt, in a dim colour, showing a suggested opening. **Right** accepts
it into the line; anything else dismisses it. It is the shell-autosuggestion pattern, and
it works in `st` today.

The point is the typing. A character costs about five button presses, so a forty-character
opener is two hundred presses. Accepting it with one is the whole feature.

### Design notes

- **Right is free.** On an empty line `_input_right` returns immediately, so nothing is
  displaced by binding it. Left is equally free and is the natural dismiss.
- **The ghost is not in the buffer.** It is drawn past the cursor and must never reach
  `INPUT_LINE`. `_input_redraw` clears what the line used to be longer by, so the ghost's
  length has to be counted in that accounting or dismissing it will leave it on screen.
- **X almost certainly cannot cancel it.** X is `st`'s keyboard toggle and is very likely
  consumed there, so the app never sees a byte. It does not matter: "anything but Right
  dismisses" reaches the same place without a special key.
- **The suggestion source is pluggable, and that is deliberate.** A ships with static
  suggestions from a config file; stage B changes where the text comes from, not how it
  behaves. A therefore waits on nothing.
- **It shares a slot with the follow-up cycler** in §8. If both happen, a live suggestion
  takes the slot while it is showing and the cycler has it otherwise.

---

## 4. Stage B — game-aware, using the switching Onion already does

**Still no daemon, no suspend, no new process. Possibly the whole feature.**

Onion switches away from a running game to an app on its own. The entire mechanism for
*getting to the app mid-game* therefore already exists and is somebody else's code to
maintain. What is left for us is small:

> On startup, work out whether a game is running or was just left, and if so make the
> stage A suggestion be about it.

That is a file read and a string, not a daemon.

### Where the game name comes from

Two candidates, neither yet confirmed on hardware. They answer slightly different
questions, which is why both are worth having.

**`/mnt/SDCARD/.tmp_update/cmd_to_run.sh`** holds the command Onion would use to resume
the current game — it is what makes auto-resume work, and Onion's own FAQ tells people to
delete it to switch that off. That makes it the better signal: it exists *because a game is
loaded right now*, which is exactly the condition the prefill should key on. The ROM path
is in the command, so the name comes from the basename with its extension stripped.

**`/mnt/SDCARD/Roms/recentlist.json`** is the recently-played list behind Onion's Recents,
carrying a `label` per entry along with `rompath` and `type`. Its `label` is the name Onion
itself displays, which is nicer than a filename — but it says what was played recently, not
what is loaded now.

So: prefer `cmd_to_run.sh` to decide **whether** to suggest anything, and prefer
`recentlist.json` for **what to call** the game, falling back to the ROM basename when no
matching entry is there. If neither file exists, there is no game and the static
suggestions from stage A apply — which is the same code path, not a special case.

### Deliberately conservative

If the game cannot be identified, the app behaves exactly as it does today. A wrong game
name in the prompt is worse than none: it would be quietly fed to the model as fact, and
the user would have to notice and correct it. Silence is the safe failure here.

That is also what makes rule 2 in §2a survivable. Both files are Onion's own working
state, not a published interface, so a future version may move, rename or restructure
either without warning. Because a missing or unreadable file means no suggestion rather
than an error, an Onion update can at worst quietly take the feature away — and the app
carries on being the app. Nothing is written, so there is nothing to leave behind or
conflict with, and no version of Onion is required.

### How A and B get delivered

Two changes, in this order, because the first needs nothing from anybody and the second is
small once it exists.

**1. The suggestion mechanism, with static text.** Ghost prefill, Right to accept, a
`suggest=` setting in `settings.cfg`. Testable entirely through `tests/keys.py` — the pty
harness already drives the editor a keystroke at a time, and a suggestion that is drawn but
not in the buffer is exactly the kind of thing that harness was built to catch. Nothing
here waits on hardware.

**2. The game as the source.** Read the two files in §4, derive a name, feed it to the
mechanism from step 1. Small, and gated only on research question 1 — which is answerable
from the SD card over SSH without touching the device UI.

Splitting it this way means step 1 ships and is useful even if the files in §4 turn out not
to say what they are documented to say.

---

## 5. Stage C — a chord that summons it directly

**A watcher on the input device, armed by the user. Only worth building if B proves the
menu route too slow.**

A watcher on `/dev/input/event0` for a held button combination, `SIGSTOP` on the emulator,
the app in the foreground, `SIGCONT` when it exits.

### `/background`, and why the install story survives

The watcher has to be alive while the app is not, so something must exist that opening the
app did not start. Rather than install anything, **the user arms it: `/background`
detaches a watcher and returns to the menu.** Go and play; the chord works; run it again to
switch it off.

This is better than starting it at boot, for a reason worth stating: **it is consented
to.** A background process that appears because someone opened an app once is a surprise.
One that appears because they typed `/background` is a feature, and one they can find,
reason about and stop. `/about` should report whether it is armed, because a thing whose
state you cannot see is a thing you cannot trust.

It satisfies rules 1 and 2 of §2a with nothing left over — no boot hook, no patched OS
files, nothing to undo at uninstall except stopping a process we started. Someone who
never runs the command never has anything running.

**It does not satisfy rule 3, and no amount of design will make it.** Suspending a live
emulator is reaching into somebody's game, and the failure mode is their unsaved progress.
That is the argument for this stage staying opt-in behind a command the user types, rather
than becoming how the app normally works — and for not starting it until B has shown that
the menu route really is too slow.

### Reading input while a game runs

The obvious worry is that an emulator holds the input device exclusively, or that watching
it costs too much during play. **Onion's own volume and brightness hotkeys work during a
game**, which is good evidence that a second reader is possible and is not ruinous. It is
evidence rather than proof — Onion's `keymon` is compiled, and ours might not be.

That is the real question: a watcher is idle until a button is pressed, and during a game
buttons are pressed constantly. In shell that is a fork per press, in the middle of the one
activity where the battery is the thing being spent.

That may be what forces a compiler — and it is worth noting how cheaply. A watcher that
blocks on an input device, matches a chord and signals is perhaps a hundred lines of C,
against the framebuffer-blending UI of stage D. If a compiler becomes necessary it becomes
necessary here first, and far more cheaply. It changes nothing about §2a either way.

### Lifecycle, if a watcher exists

Not difficulties, but they have to be answered rather than discovered:

- `/uninstall` must stop it. Deleting the folder underneath a running watcher is the worst
  version of this.
- `/update` replaces the app while a watcher from the previous version is still running and
  still pointing at the old paths. Stop and re-arm, or refuse.
- A watcher whose app has gone should exit rather than linger.
- Whatever `/background` starts must survive the app exiting, which means detaching from
  the process group Onion launched us in. The whole stage rests on that — research
  question 5.

---

## 6. Configuring the trigger

Stage C needs settings, and `app/lib/config.sh` already has the shape for them: a
whitelist of known keys, a default, and validation that warns and falls back rather than
letting a bad value surface later as something confusing.

```
# Buttons that summon the app while a game is running, and how long they must
# be held. Names are the device's own, not any emulator's mapping of them.
trigger_buttons=l2+r2
trigger_hold=5
```

- `trigger_buttons` — validated against the set of buttons the device actually reports.
  An unknown name warns and falls back to the default, exactly as `base_url` and `stream`
  already do.
- `trigger_hold` — seconds, through `_config_require_positive_int`.

**On `l2+r2` held for five seconds.** Reading `/dev/input` directly means we are not
limited to what `st` maps, so any button the hardware reports is available — including ones
the terminal ignores. `L2` and `R2` are a good choice precisely because `st` does not use
them, so nothing is stolen from the keyboard. What still needs confirming is the event
codes the Mini Plus reports for them, which is research question 4.

Five seconds is deliberately long: both triggers are held together in real games, and a
false summon mid-boss is worse than a slow one. I would expect most people to lower it once
they trust it, which is the argument for it being a setting rather than a constant. The
default should stay conservative.

---

## 7. Stage D — the translucent overlay

**A native binary. The v2 toolchain, plus framebuffer work not yet in `PLAN.md`.**

With the emulator suspended, the frame it last drew is still sitting in the framebuffer.
Copy it, blend it toward black, draw the panel and the text over the result, put it back.
The blend is a few hundred kilobytes of arithmetic per summon and is not where any
difficulty lies.

The difficulty is everything the terminal was doing for us: glyph rendering, input
decoding, the on-screen keyboard. `st` supplies all three today and none of it survives
the move.

### Why it is last

B proves the idea is worth having. C proves the summon is worth a background process. D is
presentation — the stage that makes it feel like part of the system rather than an app that
rudely takes the screen. Doing it first means building the expensive thing before knowing
whether either of the cheap ones was enough.

Consistent with `PLAN.md` §13: if D happens, the shell version stays as the fallback path
and the reference implementation.

---

## 8. Independent of all of the above

Smaller work that stands on its own, roughly in the order I would take it.

| | Why |
| --- | --- |
| **Follow-up cycler** | After a reply the next thing wanted is usually one of four: simpler, an example, shorter, keep going. Left/Right on an empty line, Enter sends. Static text, so no extra API call — the single largest reduction in typing available. |
| **Battery and WiFi in the status bar** | There is already an eight-column field on the right. Finding out you are at four percent mid-answer is a handheld failure a desktop client never has. |
| **Retry when the network drops** | `net.sh` already detects the route. A WiFi blip currently loses a question that cost two hundred button presses, which is the most infuriating failure the app can produce. |
| **PgUp / PgDn through the transcript** | Deliberately left unbound in #22 and a natural fit. Thirty rows with the keyboard covering half means replies scroll away fast, and right now they are simply gone. `history.json` makes redrawing backwards tractable. |
| **`/more`** | `max_tokens` is 512, so truncation is common and there is currently no way to say "keep going". |

---

## 9. To find out

Questions 1 to 3 are stage B. The rest belong to stages C and D and are not being worked
on; they are kept so that the reasons behind the staging survive.

1. **Do `.tmp_update/cmd_to_run.sh` and `Roms/recentlist.json` exist and hold what §4 says
   they hold?** Both come from documentation and third-party tooling, not from having
   looked at a card. Needed before stage B can read either. *Answerable from the SD card
   over SSH without touching the device UI, and it is the only thing stage B is waiting
   on.*
2. **Is `cmd_to_run.sh` removed when a game is exited, or does it linger?** Decides whether
   it means "a game is loaded" or only "a game was loaded at some point", and therefore
   whether the prefill can appear when it should not.
3. **What state does switching back leave the game in?** Not blocking — Onion owns this —
   but it decides how the feature should be described, and whether it is worth warning
   anyone about before they lose progress.
4. **Does X reach the app at all?** Decides whether stage A can bind it. One line of
   testing: press X at the prompt and see whether any byte arrives.
5. **What event codes does the Mini Plus report for `L2` and `R2`?** For §6. Reading the
   device directly means `st`'s mapping does not constrain us, but the codes have to be
   known.
6. **Does a process started by the app survive the app exiting?** `/background` rests
   entirely on this. Onion regains control when an app exits and may take the process group
   with it; `setsid` is the usual answer, but whether it is enough here is untested.
7. **What a shell input watcher costs during a game.** Every button press wakes it. If that
   is measurable against the emulator, the watcher wants to be the small native helper in
   §5 rather than a loop in `sh`.
8. **Does `st` render usably while an emulator is `SIGSTOP`ped?** If it does, stage C may
   not need a native binary at all.
9. **Framebuffer geometry and pixel format.** For stage D. We know the text grid is 53×30
   and that `st` lays out at 320×240 before doubling, which implies the panel is 320×240 —
   but the format has not been looked at.
10. **RAM headroom with an emulator suspended.** 128 MB total, and a stopped emulator keeps
   its allocation. Shell plus `curl` plus `jq` is small, but it has not been measured
   against a running game.

---

## 10. Deliberately not doing

- **Markdown rendering.** Fifty-three columns and a bitmap font. A lot of code for very
  little that would be legible at the end of it.
- **Multiple saved chats.** Already out of scope in `PLAN.md` §13, and the value is thin
  when the screen holds thirty rows.
- **Themes, and a UI for switching model.** Both are config edits, and config edits are
  fine.
- **Anything needing a compiler before it is unavoidable.** The property that this installs
  by copying a folder onto a card, with no toolchain anywhere, is worth more than any single
  feature that would cost it.
