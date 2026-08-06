#!/usr/bin/env python3
"""Report how many separate bursts stdin arrives in.

Streaming can only be distinguished from buffering by *when* bytes arrive, and
that is awkward to measure from shell. Line-based timing cannot do it at all:
the reply carries no newlines, so a reader blocking on a line sees the whole
thing at once no matter how it was delivered. `date +%s%N` is no help either,
since busybox date has no %N.

So: read a byte at a time, note the gaps, and count how many exceed a
threshold. A client that buffered the response and printed it at the end
produces one burst. A client that streams produces roughly one per event.

    ... | tests/arrival.py [--gap-ms 10]

Prints the burst count.
"""

from __future__ import annotations

import argparse
import sys
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--gap-ms",
        type=float,
        default=10.0,
        help="a pause longer than this starts a new burst",
    )
    args = parser.parse_args()

    gap = args.gap_ms / 1000.0
    stream = sys.stdin.buffer

    bursts = 0
    previous: float | None = None

    while True:
        # One byte at a time: any larger read could span a pause and hide it.
        # The volume here is a few kilobytes, so the cost does not matter.
        chunk = stream.read(1)
        if not chunk:
            break

        now = time.monotonic()
        if previous is None or (now - previous) > gap:
            bursts += 1
        previous = now

    print(bursts)


if __name__ == "__main__":
    main()
