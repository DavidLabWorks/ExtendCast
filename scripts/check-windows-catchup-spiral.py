#!/usr/bin/env python3
"""Red when Windows receiver is in backlog→keyframe→flush death spiral.

Symptom from Surface evening sessions: preferred/hard backlog breaches every
few seconds, each followed by flush for keyframe resume, while decoded frames
remain sparse.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

BACKLOG_RE = re.compile(r"Video backlog reached (\d+) ms")
FLUSH_RE = re.compile(r"flush for keyframe resume")
DECODED_RE = re.compile(r"decoded frame #(\d+).*?(\d+)x(\d+).*hw=(yes|no)")
TS_RE = re.compile(r"^\[(\d{2}):(\d{2}):(\d{2})\]")


def parse_ts(line: str) -> int | None:
    m = TS_RE.match(line)
    if not m:
        return None
    h, mi, s = map(int, m.groups())
    return h * 3600 + mi * 60 + s


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("log", type=Path)
    p.add_argument("--window-sec", type=int, default=60)
    p.add_argument("--min-backlog-events", type=int, default=8)
    p.add_argument("--min-flushes", type=int, default=6)
    args = p.parse_args()

    if not args.log.exists():
        print(f"MISSING {args.log}")
        return 2

    lines = args.log.read_text(errors="replace").splitlines()
    events = []
    for line in lines:
        ts = parse_ts(line)
        if ts is None:
            continue
        kind = None
        meta = {}
        if BACKLOG_RE.search(line):
            kind = "backlog"
            meta["ms"] = int(BACKLOG_RE.search(line).group(1))
        elif FLUSH_RE.search(line):
            kind = "flush"
        elif DECODED_RE.search(line):
            kind = "decoded"
            m = DECODED_RE.search(line)
            meta.update(frame=int(m.group(1)), w=int(m.group(2)), h=int(m.group(3)), hw=m.group(4))
        if kind:
            events.append((ts, kind, meta, line))

    if not events:
        print("NO matching receiver events")
        return 2

    # Evaluate densest window
    best = None
    for i, (ts0, _, _, _) in enumerate(events):
        j = i
        while j < len(events) and events[j][0] - ts0 <= args.window_sec:
            j += 1
        window = events[i:j]
        backlog = sum(1 for _, k, _, _ in window if k == "backlog")
        flushes = sum(1 for _, k, _, _ in window if k == "flush")
        decoded = [m for _, k, m, _ in window if k == "decoded"]
        score = (backlog, flushes)
        if best is None or score > best[0]:
            best = (score, ts0, backlog, flushes, decoded)

    (_, ts0, backlog, flushes, decoded) = best
    print(f"worst {args.window_sec}s window starting ~{ts0//3600:02d}:{(ts0%3600)//60:02d}:{ts0%60:02d}")
    print(f"backlog_events={backlog} flushes={flushes} decoded_logs={len(decoded)}")
    if decoded:
        d0, d1 = decoded[0], decoded[-1]
        print(f"decoded span frames {d0.get('frame')}→{d1.get('frame')} "
              f"{d0.get('w')}x{d0.get('h')} hw={d0.get('hw')}")

    red = backlog >= args.min_backlog_events and flushes >= args.min_flushes
    if red:
        print("VERDICT: RED — catch-up/keyframe/flush spiral")
        return 1
    print("VERDICT: GREEN — no dense catch-up spiral")
    return 0


if __name__ == "__main__":
    sys.exit(main())
