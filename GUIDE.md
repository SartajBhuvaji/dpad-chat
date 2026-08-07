# Installing D-Pad Chat

Every way to get the app onto a Miyoo Mini Plus, what each one costs you, and what to do
when one of them does not work.

If you just want the short version: [download the zip][releases], unpack it onto the root
of the SD card, put the card back, and open **Apps → D-Pad Chat**.

- [Before you start](#before-you-start)
- [Which route to pick](#which-route-to-pick)
- [Route 1 — SD card, from a release](#route-1--sd-card-from-a-release)
- [Route 2 — SD card, from a checkout](#route-2--sd-card-from-a-checkout)
- [Route 3 — over SSH](#route-3--over-ssh)
- [Route 4 — in-app, with `/update`](#route-4--in-app-with-update)
- [Setting the API key](#setting-the-api-key)
- [First launch](#first-launch)
- [Upgrading](#upgrading)
- [Uninstalling](#uninstalling)
- [Restarting the device](#restarting-the-device)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)

---

## Before you start

**A Miyoo Mini Plus.** The original Mini has no WiFi and is not supported — there is no
workaround, the radio is not there.

**Onion OS 4.x**, already installed. The app uses the `st` terminal, `curl`, `jq` and
`ntpdate` that Onion ships; it bundles none of them. Onion's own installation is
documented at [github.com/OnionUI/Onion][onion].

**WiFi configured on the device**, under Onion's **Tweaks → Network**. Test it before
installing — a failed request looks the same whether the cause is the network or the app.

**An OpenAI API key**, from [platform.openai.com/api-keys][keys].

> **Set a spending limit on the key.** It will sit in plain text on a FAT32 card, which
> has no permission bits. Anyone who picks up the handheld and pulls the card can read it.
> That is a property of the hardware, not of this app; treat the key as disposable and
> rotate it if the device leaves your hands.

---

## Which route to pick

| Route | Needs | Good for |
| --- | --- | --- |
| [1 — SD card, from a release](#route-1--sd-card-from-a-release) | a card reader | **first install**, no tooling, nothing to build |
| [2 — SD card, from a checkout](#route-2--sd-card-from-a-checkout) | a card reader, `make` | running an unreleased commit |
| [3 — over SSH](#route-3--over-ssh) | device on WiFi, SSH enabled | **repeat installs** — no reseating the card |
| [4 — in-app `/update`](#route-4--in-app-with-update) | the app already installed | **upgrading**, once you are on v0.7.0 or later |

Routes 1 and 2 need the card out of the device. Route 3 is the one to use if you expect to
install more than once; route 4 is the one to use after that.

---

## Route 1 — SD card, from a release

The ordinary path. Nothing to build and nothing to install on your computer.

1. Power the device off and take the SD card out.
2. Put the card in your computer.
3. Download `DPadChat-vX.Y.Z.zip` from [Releases][releases].
4. Unpack it onto the **root of the card** — not into a subfolder. The archive carries its
   own `App/DPadChat/` path, so the files land in the right place on their own.
5. Check that `App/DPadChat/launch.sh` exists on the card.
6. Eject the card properly, put it back in the device, and power on.
7. Open **Apps → D-Pad Chat**.

The release also carries a `.tar.gz`. It holds exactly the same files — it is what the
app's own `/update` downloads, because busybox always has `tar` and `gzip` while `unzip`
is an optional applet that may not be on the device. Use the zip here.

> On Windows, right-click the zip → **Extract All**, and set the destination to the card's
> drive letter (`E:\`, not `E:\DPadChat\`). On macOS the card usually mounts as
> `/Volumes/MIYOO`.

---

## Route 2 — SD card, from a checkout

For running a commit that has not been released.

```sh
git clone https://github.com/SartajBhuvaji/dpad-chat.git
cd dpad-chat
make install CARD=/media/you/MIYOO
```

`CARD` is wherever the card is mounted — `/Volumes/MIYOO` on macOS, a drive letter path on
Windows under WSL. The installer creates `App/DPadChat/` for you, sets the executable bits
that a Windows filesystem would otherwise drop, and leaves any existing `data/` alone.

To do it by hand instead, copy the `app/` directory to `App/DPadChat/` on the card and
`chmod +x` `launch.sh`, `chat.sh` and `apply-update.sh`.

---

## Route 3 — over SSH

The fastest route, and the one worth setting up if you are going to install more than
once. No card reader, no power cycling.

**Enable SSH first**, on the device: **Tweaks → Network → SSH**. Note the device's IP,
shown on the same screen.

```sh
make install-ssh HOST=192.168.1.42              # the app
make install-key HOST=192.168.1.42              # the app, then prompt for the API key
```

The login is the **device's**, not your computer's and not your WiFi password. Onion's
default is `onion` / `onion`. If you changed it, pass `USER=`:

```sh
make install-ssh HOST=192.168.1.42 USER=me
```

You are asked for the password once. The connection is multiplexed, so the copy and the
key write share the single authentication.

`install-key` prompts with the input hidden and hands the key to the device over stdin. It
never appears in your shell history, in `ps` on either machine, or in the device's process
list. Settings already on the device are preserved — only `api_key` is rewritten, so a
model or timeout you set there survives a reinstall.

For scripted use, where a prompt is not possible:

```sh
tools/install.sh --ssh 192.168.1.42 --key-file ~/.config/openai-key
```

> **Onion also offers FTP** (`bftpd`, under Tweaks). It works, but it sends the login *and*
> anything you upload in cleartext over your network — including the API key. That undoes
> the point of verifying TLS on every request. SSH is already there and costs one prompt.

---

## Route 4 — in-app, with `/update`

Once you are running v0.7.0 or later, the app updates itself. Open it and type:

```
/update
```

It asks GitHub for the latest release. If it is newer than what you are running, it shows
you both versions and waits:

```
New version available:
  v0.7.0  ->  v0.8.0

Download and install it? [y/N]
```

Nothing is downloaded before you answer. Answering yes unpacks the release beside the app
and stops there — **the swap happens on the next launch.** Quit, reopen from the Apps
menu, and you are on the new version.

That two-step is not caution for its own sake. The shell reads a script incrementally from
an open file descriptor, so writing over `chat.sh` while it is running would resume the
interpreter partway through different content. Unpacking first and swapping at launch is
the only ordering where nothing is being overwritten while it executes.

Your conversation and settings live in `data/`, which an update never writes to.

`/update` is manual. The app never checks on its own, and never contacts GitHub unless you
ask it to.

---

## Setting the API key

The app runs without a key — it starts, and `/help` explains what is missing — but it
cannot send anything until one is set. Three ways, best first:

**Over SSH,** if the app is already installed:

```sh
make install-key HOST=192.168.1.42
```

**On the card,** with the card in your computer. Create or edit
`App/DPadChat/data/settings.cfg`:

```ini
api_key = sk-...
```

Create the `data/` directory if it is not there — it is made at first run, so a fresh
install will not have one yet.

**On the device,** over SSH, if you would rather not pull the card:

```sh
ssh onion@192.168.1.42
mkdir -p /mnt/SDCARD/App/DPadChat/data
vi /mnt/SDCARD/App/DPadChat/data/settings.cfg
```

The file is parsed against a whitelist of known keys rather than sourced, so nothing
written in it is ever executed. Unknown keys are logged and ignored. Every setting is
listed in [COMMANDS.md](COMMANDS.md#settings).

Check it took with `/about`, which shows the key redacted to its first six and last four
characters.

---

## Keeping your key safe

The key lives in `data/settings.cfg` on a FAT32 card. FAT has no permission bits, so
`chmod` is advisory at best — **anyone holding the card can read the key.** That is the
storage, not the app, and there is no way around it on this hardware.

What follows from that:

- **Set a spending limit** on the key at [platform.openai.com][keys]. Treat it as
  disposable.
- **Revoke it** if the device or the card leaves your hands.
- **Do not use FTP** to put it there. Onion offers `bftpd` under Tweaks, and it sends the
  login and the file in cleartext across your network.

What the app does control, it holds to a stricter line than Onion's own scripts do — those
call `curl -k`. This one ships a CA bundle and verifies every connection, because every
request carries the key. **There is no insecure fallback:** a missing bundle fails the
request rather than downgrading it. The key never reaches the log, never appears in full on
screen, and is handed to `curl` through a mode-600 config file rather than the command
line where any other process could read it. `/update` downloads code, so it is held to the
same rule again, and never sends your key to GitHub.

The reasoning is in [PLAN.md §7 and §12](PLAN.md); all of it is covered by tests.

## First launch

Open **Apps → D-Pad Chat**. You should get a mostly empty screen with a status bar across
the top and the controls pinned across the bottom.

Press **X** to raise the on-screen keyboard, D-pad to move the cursor, **A** to press a
key, **Start** to send. Press **X** again to hide the keyboard and read the reply — it
covers the bottom half of the screen, so replies of any length want it out of the way.

Type `/about` first. It reports the version, the terminal width, the model, whether TLS is
verified and how many trust anchors are loaded, and whether the key is set. If something
is wrong, that screen usually says what.

The full control and command reference is in [COMMANDS.md](COMMANDS.md).

---

## Upgrading

| What you do | What happens to your chat and settings |
| --- | --- |
| `/update` from inside the app | kept — `data/` is never written to |
| `make install-ssh` over an existing install | kept — only `api_key` is touched, and only by `install-key` |
| `make install CARD=` over an existing install | kept — `data/` is left alone |
| Unzipping a release over the card | kept — the archive contains no `data/` |

In every case the conversation and the settings survive, because none of the four ever
writes into `data/`. The only thing that clears a conversation is `/clear`, which is
final — no copy is kept anywhere.

If you want a genuinely clean install, delete `App/DPadChat/` from the card first.

---

## Uninstalling

**From the device.** Open the app and type `/uninstall`. It says what will go, asks
twice, and then deletes `App/DPadChat/` — the app, your key, the conversation and the
log. Press **Select** on the report to return to the Apps menu.

```
Uninstalling deletes this folder:
  /mnt/SDCARD/App/DPadChat

Your API key, this chat and the log go
with it. Nothing is kept, and there is
no undo.

Uninstall D-Pad Chat? [y/N]
```

Onion reads the Apps menu at boot, so the tile may still be there until you restart the
device. Opening it after the folder is gone does nothing.

**From a computer.** Delete `App/DPadChat/` from the SD card. That is the whole install —
nothing is written outside that folder, and nothing is registered anywhere else. This is
also the way out if the card is write-protected, which is the one thing `/uninstall`
cannot work around: it reports the failure and leaves the app running.

**Your API key is in `App/DPadChat/data/settings.cfg`.** If the card or the device is
going to someone else, delete the folder rather than just removing the app from the menu,
and consider revoking the key at [platform.openai.com/api-keys][keys].

There is no uninstall entry in Onion's Apps menu, and no app can add one: that menu is
MainUI's, and an app cannot put a command into the list that launches it. `/uninstall` is
inside the app for the same reason `/update` is.

---

## Restarting the device

Onion reads the Apps menu at boot, so after installing, uninstalling or moving a folder,
you need a restart before the change shows up. Holding **POWER** for a few seconds is a
safe shutdown, and pressing it again boots — that is the no-computer way to do it, and it
is enough most of the time.

It has one catch. Onion records what was running in `.tmp_update/cmd_to_run.sh` and
replays it, so a power cycle in the middle of a game puts you back in the game rather than
at the menu.

From a checkout:

```sh
make reboot HOST=192.168.1.42
```

```
This restarts onion@192.168.1.42 now.
Any unsaved game progress is lost.
Any stale auto-resume is cleared.

Restart? [y/N]
```

It clears any leftover auto-resume, flushes the card, and restarts. Options:

| Option | Effect |
| --- | --- |
| `--off` | shut down instead of restarting |
| `--keep-resume` | leave a leftover auto-resume file alone |
| `--yes` | do not ask |

**It costs unsaved progress.** Holding POWER lets Onion write a save state first; this
does not wait for one. That is the point — it is for clearing the device, not for putting
it down — but it is why it asks, and why piping into it is refused rather than taken as a
yes.

It refuses any host without a `/mnt/SDCARD/.tmp_update` on it, so a mistyped address that
happens to answer SSH is not restarted. Use `tools/reboot.sh --print-remote` to see
exactly what would run on the device.

**It needs the device to be reachable, and a running game may be enough to stop that.**
Trying it with a game in the foreground gave `Connection refused` — something answered at
that address and rejected port 22, so the device was either off the network or not
listening. Pressing **Menu** to come out of the game first is the workaround. If the
address itself is in doubt, check it under Tweaks > Network on the device, since a device
that drops off WiFi can come back on a different one.

That is a real limit of doing this over SSH rather than on the device, and it is worth
knowing before reaching for it mid-game.

**On `cmd_to_run.sh`, and what is actually known.** It was absent on a running device with
a game going, and absent again just after a boot — both measured, not read somewhere. What
fits that, and Onion's own instruction to delete it *with the card in a PC*, is that it is
written as the device shuts down and consumed at boot when it is replayed: it exists only
while the device is off. So `resume: nothing to clear` is the ordinary answer here, and
what the clear really catches is one left behind by an unclean shutdown — the boot-loop
case. Whether restarting this way lets Onion write a fresh one on the way down has not
been established.

---

## Troubleshooting

**The app is not in the Apps menu.**
Check the path is exactly `/mnt/SDCARD/App/DPadChat/config.json` — one level too deep is
the usual cause, from unzipping into a subfolder instead of the card root. Onion reads the
menu at boot, so power-cycle after fixing it.

**`chat.sh: not found`, but the file is right there.**
The scripts have Windows line endings. The device execs them by their shebang, and a CR
at the end of `#!/bin/sh` makes the kernel look for an interpreter named `/bin/sh\r` — so
the thing reported as missing is the interpreter, not the script, and the message does not
say so.

Check it over SSH:

```sh
head -1 /mnt/SDCARD/App/DPadChat/chat.sh | od -c | head -1
```

If the first line ends `s h \r \n` rather than `s h \n`, that is it. Fix it in place:

```sh
cd /mnt/SDCARD/App/DPadChat
for f in chat.sh launch.sh apply-update.sh lib/*.sh; do
    sed -i 's/\r$//' "$f"
done
```

Or reinstall from a [release][releases] zip, which is built on Linux and never carries
them. This only happens when installing from a checkout on a Windows filesystem;
`.gitattributes` pins the endings and `make check` refuses to lint a tree that has them,
so a fresh clone is not affected.

**It appears but does nothing when launched.**
Almost always a missing executable bit, which Windows and macOS filesystems drop when
copying. Over SSH:

```sh
chmod +x /mnt/SDCARD/App/DPadChat/launch.sh \
         /mnt/SDCARD/App/DPadChat/chat.sh \
         /mnt/SDCARD/App/DPadChat/apply-update.sh
```

The release archives set these explicitly, so this only happens when copying by hand.

**"No API key set."**
See [Setting the API key](#setting-the-api-key). `/about` confirms whether one was read.

**"No network. Connect to WiFi in Onion settings."**
The app reads the kernel routing table before sending, so this means the device genuinely
has no default route. Fix WiFi in Onion's settings, then try again — the status bar
switches from `offline` back to `ready` on its own when the route comes back.

**"The clock is wrong, so TLS cannot be verified."**
These handhelds have no RTC battery and boot at a factory date. The app tries `ntpdate`
itself; if that fails, set the time in Onion's settings. A wrong clock makes every
certificate look expired, which reads as a security failure rather than as the dead
battery it is.

**"Missing CA bundle."**
`res/cacert.pem` did not make it onto the card. Reinstall. The app will not fall back to
an unverified connection, because the thing it would be sending is your key.

**Replies are cut off, or a word is split across lines.**
Streaming lets the terminal wrap, which can break a word. Set `stream = false` in
`settings.cfg` for the buffered path, which wraps on word boundaries at the cost of a
five-to-ten-second wait with nothing on screen. `max_tokens` caps the reply length.

**The keyboard covers the reply.**
Press **X** to hide it. This is `st`'s keyboard, drawn over the screen rather than beside
it, so there is no layout that fits both.

**Something else.**
The app logs to `App/DPadChat/data/dpad-chat.log`, rotated at 256 KB. It records every
request's endpoint, model and HTTP status, and never the key. That file is the right thing
to attach to an issue.

---

## Building from source

No cross-compiler. The app is POSIX shell calling binaries Onion already ships, so a
checkout runs on your machine as-is.

```sh
git clone https://github.com/SartajBhuvaji/dpad-chat.git
cd dpad-chat
make check
```

| Target | Does |
| --- | --- |
| `make check` | lint + the full test suite. The default |
| `make sim` | run the app locally, pinned to the device's 53-column terminal |
| `make mock` | run the mock API on `:8080` to poke at by hand |
| `make test-docker` | the same suite under Alpine's busybox ash |
| `make package` | build `dist/DPadChat-vX.Y.Z.zip` and `.tar.gz` |
| `make icon` | regenerate `app/res/icon.png` from its source art |
| `make cacert` | refresh the bundled CA certificates |
| `make version` | what version this checkout is |

**The suite needs no API key and costs nothing.** It drives the client against
`tools/mockapi.py`, a scriptable stand-in for the API and for GitHub releases — a live
endpoint cannot be asked to return 429 on demand, and proving that word wrap works should
not spend tokens. Scenarios are chosen by the prompt itself:

```
scenario:unauthorized
```

Available: `ok`, `long`, `multiline`, `unauthorized`, `rate_limit`, `rate_limit_always`,
`server_error`, `malformed`, `empty`, `slow`, `echo_payload`.

**The device shell is busybox ash,** so the code stays strict POSIX: no arrays, no
`[[ ]]`, no `$'...'`, no `local`. `make check` runs `dash -n` and `shellcheck -s sh` over
every script — but it *skips* either one if it is not installed and only says so in
passing, while CI does not skip. Run `make test-docker` before opening a pull request:
Alpine's busybox is the closest available stand-in for the device userland, and it catches
things a laptop will not.

### Testing against real hardware

Enable SSH in Onion's Tweaks, then run the app over the network without going through the
Apps menu:

```sh
make install-ssh HOST=<device-ip>
ssh -t onion@<device-ip> /mnt/SDCARD/App/DPadChat/chat.sh
```

This exercises everything except `st`'s keyboard, and iterates in seconds. Launch from the
Apps menu for the final check.

Design notes, the milestone history and the open hardware questions are in
[PLAN.md](PLAN.md).

[releases]: https://github.com/SartajBhuvaji/dpad-chat/releases
[onion]: https://github.com/OnionUI/Onion
[keys]: https://platform.openai.com/api-keys
