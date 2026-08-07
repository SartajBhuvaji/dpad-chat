# Roadmap

`PLAN.md` records what was built and why. This records where it is going, and — more
usefully — what has to be found out before parts of it can be costed at all.

Nothing here is committed to. The staging exists so that the expensive work is done last,
after the cheap work has proved it is the right work.

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

## 2a. Installing must not get harder

Today the whole install is: copy a folder onto the card, open it from Apps, set a key.
Nothing is registered, nothing runs at boot, nothing is patched. Uninstalling is deleting
the folder. That property is worth more than any single feature here.

Stages A, B and D leave it untouched. A and B are code inside the app. D is a
cross-compiled binary, which for the user is still just a file in the folder being copied
— the toolchain cost is ours at build time, not theirs at install time, and the release
stays a zip of `App/DPadChat/`.

**Stage C is the only one that could break it**, because a hotkey must be watched while
the app is not running. `/background` in §5 is how it does not.

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

Onion can switch away from a running game to an app. If that is so, the entire mechanism
for *getting to the app mid-game* already exists and is somebody else's code to maintain.
What is left for us is small:

> On startup, work out whether a game is running or was just left, and if so make the
> stage A suggestion be about it.

That is a config read and a string, not a daemon. It needs answers to research questions 1
and 2 and nothing else.

**This is the cheapest possible version of the idea, and it may be the only one worth
building.** It should be attempted before stage C is designed at all, because if switching
is pleasant enough in practice, a custom chord is a convenience rather than a feature — and
convenience does not justify a background process.

What it does not give you is the *speed* of the idea in §1: a chord is one gesture, and
going out to a menu and picking an app is several. Whether that gap matters is a question
about how it feels, and the only way to answer it is to build B and use it.

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

It keeps §2a intact with nothing left over — no boot hook, no patched OS files, nothing to
undo at uninstall except stopping a process we started. Someone who never runs the command
never has anything running.

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

Ordered so that the cheap answers that could cancel expensive work come first.

1. **Can Onion switch from a running game to an App, and what does it leave the game in?**
   This is the whole of stage B, and if it is a good experience it may cancel stage C.
   Answerable in a minute on hardware: start a game, switch to D-Pad Chat, see what
   happens — and then see whether the game is still there afterwards.
2. **Where does Onion record the game currently running, or last run?** Needed for the
   game-aware prefill regardless of which stage delivers it.
3. **Does X reach the app at all?** Decides whether stage A can bind it. One line of
   testing: press X at the prompt and see whether any byte arrives.
4. **What event codes does the Mini Plus report for `L2` and `R2`?** For §6. Reading the
   device directly means `st`'s mapping does not constrain us, but the codes have to be
   known.
5. **Does a process started by the app survive the app exiting?** `/background` rests
   entirely on this. Onion regains control when an app exits and may take the process group
   with it; `setsid` is the usual answer, but whether it is enough here is untested.
6. **What a shell input watcher costs during a game.** Every button press wakes it. If that
   is measurable against the emulator, the watcher wants to be the small native helper in
   §5 rather than a loop in `sh`.
7. **Does `st` render usably while an emulator is `SIGSTOP`ped?** If it does, stage C may
   not need a native binary at all.
8. **Framebuffer geometry and pixel format.** For stage D. We know the text grid is 53×30
   and that `st` lays out at 320×240 before doubling, which implies the panel is 320×240 —
   but the format has not been looked at.
9. **RAM headroom with an emulator suspended.** 128 MB total, and a stopped emulator keeps
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
