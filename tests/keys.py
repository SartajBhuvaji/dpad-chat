#!/usr/bin/env python3
"""Run a command on a pseudo-terminal and feed it keystrokes.

The line editor only exists when stdin and stdout are terminals, so testing it
through a pipe tests the fallback and nothing else. This gives the command
under test a real terminal.

The hard part is timing. A pty starts in canonical mode with echo on, so
anything written before the child has taken the terminal raw is echoed by the
kernel, and the capture is then a mixture of the kernel's echo and the
program's. Sleeping for a moment first is the usual workaround, and it is a
race that fails on a loaded CI runner.

Instead the terminal itself is polled: the parent waits for ECHO to be cleared
before writing a single byte. That removes the race, and it also asserts the
thing the test cares about most, since a command that never enters raw mode
never gets its input.

    tests/keys.py --input 'ab\\033[Hcd\\r' -- ./driver.sh
    tests/keys.py --cols 10 --input 'abcdefghijk\\177\\r' -- ./driver.sh

Everything the command writes to the terminal is reproduced on stdout, so the
caller can assert on what was echoed. The exit status is the command's.

A new pty has a window size of zero, which is what a terminal reports when it
does not know its own size. The editor treats that as "width unknown" and stops
tracking wraps, so the size is always set here - and being able to set it small
is what makes wrapping testable in a handful of characters.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

# Generous: these commands do nothing but read a short line. It exists so a
# hang shows up as a failed test rather than a wedged CI job.
TIMEOUT = 30.0

# How long to wait for the command to take the terminal raw before giving up
# and writing anyway. The fallback path never clears ECHO, and it is a
# supported way to run, so waiting forever would be wrong.
RAW_TIMEOUT = 5.0


def decode(text: str) -> bytes:
    r"""Turn the literal backslash escapes in an argument into bytes.

    Written as \033 and \r in the test so the sequences read the way they are
    documented. latin-1 maps the code points back to the single bytes they came
    from; the keyboard sends bytes, not text.
    """
    return text.encode("latin-1", "backslashreplace").decode("unicode_escape").encode(
        "latin-1"
    )


def set_window_size(fd: int, cols: int, rows: int) -> None:
    """Tell the terminal how big it is, so `stty size` reports something."""
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def echo_is_off(fd: int) -> bool:
    try:
        return not termios.tcgetattr(fd)[3] & termios.ECHO
    except termios.error:
        # The slave side is gone, which means the child has exited.
        return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="", help="keystrokes, with escapes")
    parser.add_argument("--cols", type=int, default=80, help="terminal width")
    parser.add_argument("--rows", type=int, default=24, help="terminal height")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        sys.exit("pty: no command given")

    keystrokes = decode(args.input)

    pid, master = pty.fork()
    if pid == 0:
        # pty.fork has already made the slave this process's controlling
        # terminal on all three descriptors.
        #
        # Sized here rather than from the parent because the parent races the
        # exec: the command can be running, and can have read its width, before
        # a parent-side ioctl lands. Before the exec there is no race to lose.
        try:
            set_window_size(0, args.cols, args.rows)
        except OSError:
            pass

        try:
            os.execvp(command[0], command)
        except OSError as exc:
            print(f"pty: cannot run {command[0]}: {exc}", file=sys.stderr)
        os._exit(127)

    deadline = time.monotonic() + TIMEOUT
    raw_deadline = time.monotonic() + RAW_TIMEOUT
    pending = keystrokes
    captured = bytearray()

    while time.monotonic() < deadline:
        if pending and (echo_is_off(master) or time.monotonic() > raw_deadline):
            os.write(master, pending)
            pending = b""

        # A short poll rather than a blocking one, because the terminal going
        # raw is not an event select can wait on.
        try:
            ready, _, _ = select.select([master], [], [], 0.02)
        except OSError:
            break

        if not ready:
            continue

        try:
            chunk = os.read(master, 4096)
        except OSError as exc:
            # The master reports EIO once the last slave descriptor closes,
            # which is this platform's way of saying end of output.
            if exc.errno in (errno.EIO, errno.EBADF):
                break
            raise

        if not chunk:
            break
        captured.extend(chunk)

    os.close(master)

    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0

    sys.stdout.buffer.write(bytes(captured))
    sys.stdout.buffer.flush()

    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 1


if __name__ == "__main__":
    sys.exit(main())
