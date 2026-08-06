#!/usr/bin/env python3
"""Red when Mac is streaming full-rate to Windows without headroom.

Known stutter path: D3D11VA decode + GPU→CPU transfer + OpenGL upload at
2880x1920@60. HW decode keeps user clarity/FPS; lower FPS in the UI if present
path falls behind until zero-copy present lands.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


PIPELINE_RE = re.compile(
    r"pipeline start .*?"
    r"streamCapacity=(?P<cap>\d+x\d+@\d+) "
    r"capacityLimited=(?P<limited>true|false)"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "log",
        nargs="?",
        default=str(
            Path.home()
            / "Library/Application Support/ExtendCast/Diagnostics/connection.log"
        ),
    )
    parser.add_argument("--day", default=None, help="YYYY-MM-DD filter")
    args = parser.parse_args()

    path = Path(args.log)
    if not path.exists():
        print(f"MISSING {path}")
        return 2

    lines = path.read_text(errors="replace").splitlines()
    if args.day:
        lines = [line for line in lines if args.day in line]

    pipelines = []
    for line in lines:
        if "pipeline start" not in line or "(Windows)" not in line:
            continue
        match = PIPELINE_RE.search(line)
        if not match:
            continue
        pipelines.append((line, match.groupdict()))

    if not pipelines:
        print("NO Windows pipeline starts found")
        return 2

    _, last = pipelines[-1]
    limited = last["limited"] == "true"
    cap = last["cap"]
    risky = (not limited) and ("2880x1920@60" in cap or "@60" in cap)

    print(f"last capacity={cap} capacityLimited={last['limited']}")
    print(f"windows pipeline starts scanned={len(pipelines)}")
    if risky:
        print(
            "VERDICT: RED — full-rate Windows stream without present lease "
            "(HW+OpenGL transfer risk)"
        )
        return 1

    print("VERDICT: GREEN — present-bound or below full-rate risk profile")
    return 0


if __name__ == "__main__":
    sys.exit(main())
