# Roadmap

`PLAN.md` records what was built and why. This records where it is going, and — more
usefully — what has to be found out before parts of it can be costed at all.

Nothing here is committed to. The staging exists so that the expensive work is done last,
after the cheap work has proved it is the right work.

---

## 1. The idea

Ask a question without putting the game down.

You are stuck on a boss. You press a button combination, the game freezes where it is, a
panel fades up over it already holding *"I'm playing Chrono Trigger — "*, you type only
the part that is actually your question, you read the answer, you press the combination
again and the frame you left resumes.

That is a use case no desktop client has, and it is the reason to run this on a handheld
rather than reach for the phone sitting next to it.

---

## 2. Why this is not one feature

It reads like an extension of the app. It is not, and the reason is worth being exact
about, because it decides the whole shape of the work.

Everything built so far runs inside `st`, Onion's terminal. That is what gives us the
on-screen keyboard for free, and it is why a shell script is a viable client at all. It
also rules out three things at once:

- **A terminal cannot be translucent.** It draws opaque character cells. There is no
  alpha anywhere in the model.
- **A terminal cannot appear over a running game.** The emulator owns the framebuffer and
  rewrites it every frame. Anything drawn over it is gone in about sixteen milliseconds.
- **There is no compositor.** The Miyoo has one framebuffer and nothing that stacks
  surfaces onto it. "Windows on top of other windows" is not a service this system offers.

So a translucent panel over a live game is not a flag we pass to `st`. It is a program
that reads `/dev/fb0`, blends its own pixels with what the game last drew, renders text
with its own font, and reads `/dev/input/event0` itself. That is C, and it is the
cross-compile path `PLAN.md` §13 defers.

None of that argues against doing it. It argues against starting there — because two
thirds of what makes the idea good can be had without any of it.

---

## 3. Stage A — the prefill, in the terminal we already have

**Ships inside the current app. No new binary, no new process.**

Ghost text at the prompt, in a dim colour, showing a suggested opening. **Right** accepts
it into the line; anything else dismisses it. It is the shell-autosuggestion pattern, and
it works in `st` today.

The point is the typing. A character costs about five button presses, so a forty-character
opener is two hundred presses. Accepting it with one is the whole feature.

### Why it comes first

It is the part of the idea that carries the value, and it is completely independent of the
overlay. If stages B and C never happen, this still earns its place — a suggested opener
is worth having at a prompt you reached from the menu, too.

### Design notes

- **Right is free.** On an empty line `_input_right` returns immediately, so nothing is
  displaced by binding it. Left is equally free and is the natural dismiss.
- **The ghost is not in the buffer.** It is drawn past the cursor and must never reach
  `INPUT_LINE`. `_input_redraw` clears what the line used to be longer by, so the ghost's
  length has to be counted in that accounting or dismissing it will leave it on screen.
- **X almost certainly cannot cancel it.** X is `st`'s keyboard toggle and is very likely
  consumed there, so the app never sees a byte — see the research questions. It does not
  matter: "anything but Right dismisses" reaches the same place without a special key.
- **The suggestion source is pluggable, and that is deliberate.** Stage A ships with
  static suggestions from a config file. Making them game-aware is a change of source, not
  of mechanism, so A does not wait on any of the Onion research below.
- **It shares a slot with the follow-up cycler** in §6. If both happen, a live suggestion
  takes the slot while it is showing and the cycler has it otherwise.

---

## 4. Stage B — summon it over a running game

**Full-screen and opaque. No transparency, but the actual behaviour.**

A watcher on `/dev/input/event0` for a button chord, `SIGSTOP` on the emulator, the app in
the foreground, `SIGCONT` when it exits.

Onion's own in-game menu already suspends a running game to draw over it, so the pattern
is proven on this hardware — the question is only how much of it can be borrowed rather
than rebuilt.

This is where the idea becomes real. It is also, I would guess, most of the felt value:
the difference between *asking without putting the game down* and *asking without putting
the game down, prettily*.

### What makes it uncertain

Its cost is not known within an order of magnitude yet, and that is entirely down to
research question 1. If Onion's in-game menu can be extended, B is a small piece of
integration. If it cannot, B is a daemon that has to be correct about process groups,
input grabbing and resume, and that is a different size of job.

**Nothing should be estimated here until that question is answered.**

---

## 5. Stage C — the translucent overlay

**A native binary. The v2 toolchain, plus framebuffer work not yet in `PLAN.md`.**

With the emulator suspended, the frame it last drew is still sitting in the framebuffer.
Copy it, blend it toward black, draw the panel and the text over the result, put it back.
The blend is a few hundred kilobytes of arithmetic per summon and is not where any
difficulty lies.

The difficulty is everything a terminal was doing for us: glyph rendering, input decoding,
the on-screen keyboard. `st` supplies all three today and none of it survives the move.

### Why it is last

A proves the interaction is worth having. B proves the summon works and is pleasant. C is
presentation — the stage that makes it feel like part of the system rather than an app
that rudely takes the screen. Doing it first would mean building the expensive thing before
knowing whether the cheap thing was right.

Consistent with `PLAN.md` §13: if C happens, the shell version stays as the fallback path
and the reference implementation.

---

## 6. Independent of all of the above

Smaller work that stands on its own, roughly in the order I would take it.

| | Why |
| --- | --- |
| **Follow-up cycler** | After a reply the next thing wanted is usually one of four: simpler, an example, shorter, keep going. Left/Right on an empty line, Enter sends. Static text, so no extra API call — the single largest reduction in typing available. |
| **Battery and WiFi in the status bar** | There is already an eight-column field on the right. Finding out you are at four percent mid-answer is a handheld failure a desktop client never has. |
| **Retry when the network drops** | `net.sh` already detects the route. A WiFi blip currently loses a question that cost two hundred button presses, which is the most infuriating failure the app can produce. |
| **PgUp / PgDn through the transcript** | Deliberately left unbound in #22 and a natural fit. Thirty rows with the keyboard covering half means replies scroll away fast, and right now they are simply gone. `history.json` makes redrawing backwards tractable. |
| **`/more`** | `max_tokens` is 512, so truncation is common and there is currently no way to say "keep going". |

---

## 7. To find out before B or C can be costed

Ordered by how much they change the plan. The first one is worth more than the rest
together.

1. **Is Onion's in-game menu extensible?** If an entry can be added to something that
   already knows how to suspend a game and take the screen, most of stage B disappears and
   some of C gets easier. If not, both get substantially larger. *Read Onion's `keymon` and
   in-game menu source.*
2. **Where does Onion record the game currently running?** Needed for the game-aware
   prefill regardless of which stage delivers it.
3. **Does `st` render usably while an emulator is `SIGSTOP`ped?** If it does, stage B may
   not need a native binary at all. If the emulator holds the framebuffer in a way that
   survives being stopped, B needs more of C than assumed.
4. **Does X reach the app at all?** Decides whether stage A can bind it, and is one line
   of testing on hardware: press X at the prompt and see whether any byte arrives.
5. **Framebuffer geometry and pixel format.** For C. We know the text grid is 53×30 and
   that `st` lays out at 320×240 before doubling, which implies the panel is 320×240 —
   but the format has not been looked at.
6. **RAM headroom with an emulator suspended.** 128 MB total, and a stopped emulator keeps
   its allocation. Shell plus `curl` plus `jq` is small, but it has not been measured
   against a running game.

---

## 8. Deliberately not doing

- **Markdown rendering.** Fifty-three columns and a bitmap font. A lot of code for very
  little that would be legible at the end of it.
- **Multiple saved chats.** Already out of scope in `PLAN.md` §13, and the value is thin
  when the screen holds thirty rows.
- **Themes, and a UI for switching model.** Both are config edits, and config edits are
  fine.
- **Anything needing a compiler before stage C.** The property that this installs by
  copying a folder onto a card, with no toolchain anywhere, is worth more than any single
  feature that would cost it.
