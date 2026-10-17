#!/usr/bin/env python3
"""Records a real shell session as an asciicast v2 file, typing each
command at a human pace.

    record.py out.cast COLS ROWS 'shell command' 'cmd 1' 'cmd 2' ...

Turn it into a GIF with agg (https://github.com/asciinema/agg).
"""

import json
import os
import pty
import random
import select
import sys
import time


def main():
    out, cols, rows, shell, *commands = sys.argv[1:]
    cols, rows = int(cols), int(rows)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["COLUMNS"], os.environ["LINES"] = str(cols), str(rows)
        os.execvp("sh", ["sh", "-c", "stty cols %d rows %d; exec %s" % (cols, rows, shell)])

    start = time.monotonic()
    events = []

    def pump(seconds):
        """Records output for `seconds`."""
        end = time.monotonic() + seconds
        while (left := end - time.monotonic()) > 0:
            ready, _, _ = select.select([fd], [], [], left)
            if ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return
                events.append([round(time.monotonic() - start, 4), "o", data.decode("utf-8", "replace")])

    pump(1.5)  # shell startup, not recorded
    events.clear()
    start = time.monotonic()
    os.write(fd, b"\x0c")  # clear the screen: the recording starts at a fresh prompt
    pump(1.0)
    rnd = random.Random(7)
    for cmd in commands:
        for ch in cmd:
            os.write(fd, ch.encode())
            pump(rnd.uniform(0.04, 0.11))
        pump(0.35)
        os.write(fd, b"\r")
        pump(3.2 if "sleep" in cmd.lower() else 1.1)
    pump(1.5)
    os.kill(pid, 9)

    with open(out, "w", encoding="utf-8") as f:
        f.write(json.dumps({"version": 2, "width": cols, "height": rows, "env": {"TERM": "xterm-256color"}}) + "\n")
        for e in events:
            f.write(json.dumps(e) + "\n")


if __name__ == "__main__":
    main()
