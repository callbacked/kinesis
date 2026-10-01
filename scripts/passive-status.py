#!/usr/bin/env python3
"""Checks on "record while I work": what it is doing now, and what the data covers.

    scripts/passive-status.py          status, every day's totals, and coverage
    scripts/passive-status.py --today  only today's recordings

Coverage is what a trackpad decoder needs: one-finger slides in every direction,
at slow and quick speeds, over the whole trackpad, plus two- and three-finger
gestures. Gaps in it are listed, so the next session can fill them.
"""
import importlib.util
import json
import math
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

here = Path(__file__).parent
spec = importlib.util.spec_from_file_location("train", here / "trackpad-train.py")
train = importlib.util.module_from_spec(spec)
spec.loader.exec_module(train)

ROOT = train.check.LAB / "passive"
DIRECTIONS = ["right", "up-right", "up", "up-left", "left", "down-left", "down", "down-right"]


def minutes(seconds):
    if seconds < 60:
        return f"{seconds:.0f} s"
    m = int(seconds // 60)
    return f"{m // 60} h {m % 60:02d} min" if m >= 60 else f"{m} min"


def segment_coverage(folder):
    """One-finger slide directions, speeds, and positions, and multi-finger gestures."""
    frames = train.read_touches_bin(folder / "touches.bin")
    directions = np.zeros(8)
    speeds, positions = [], []
    gestures = {2: 0, 3: 0}
    previous, fingers_before = None, 0
    for (t, contacts), (t_next, _) in zip(frames, frames[1:] + [(math.inf, [])]):
        touching = [c for c in contacts if c[1] in train.TOUCHING]
        fingers = [c for c in touching if c[2] < train.PALM_SIZE]
        count = len(fingers) if len(fingers) == len(touching) else 0
        if count in (2, 3) and fingers_before < count:
            gestures[count] += 1
        if count == 1 and previous and 0 < t - previous[0] < 0.1:
            dx, dy = fingers[0][3] - previous[1], fingers[0][4] - previous[2]
            dt = t - previous[0]
            speed = math.hypot(dx, dy) / dt
            if speed > 20:
                directions[int(((math.degrees(math.atan2(dy, dx)) + 22.5) % 360) // 45)] += dt
                speeds.append(speed)
                positions.append((fingers[0][3], fingers[0][4]))
        previous = (t, fingers[0][3], fingers[0][4]) if count == 1 else None
        fingers_before = count
    return directions, speeds, positions, gestures


def quality(folder):
    """sEMG samples a second while it flowed (2048 is all), and how long it flowed."""
    path = folder / "emg.bin"
    if not path.exists() or path.stat().st_size < 280 * 2:
        return 0.0, 0.0
    try:
        times, _ = train.read_emg_bin(path)
    except (OSError, ValueError):
        return 0.0, 0.0
    span = times[-1] - times[0]
    return len(times) / max(span, 1e-3), span


def main():
    only_today = "--today" in sys.argv
    status_file = ROOT / "status.json"
    if status_file.exists():
        s = json.load(open(status_file))
        print(f"now: {s['status']}  (updated {s['updated']})")
        if "warning" in s:
            print(f"  warning: {s['warning']}")
        print(f"  sEMG {s['emgRate'] / 20.48:.0f}% of samples arriving, trackpad {s['trackpadRate']:.0f} frames/s")
    else:
        print("now: no status yet. turn on \"record while I work\" in a dev build.")

    live = train.check.LAB / "decoder-live.plist"
    if live.exists():
        import plistlib
        try:
            state = plistlib.load(open(live, "rb"))
            print(f"  decoder learned from {minutes(state['learned'])} of trackpad use on wearing {state['wearing']}, "
                  f"fine-tuned {state['tunes']} time(s)")
        except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
            pass

    segments = []
    for meta in sorted(ROOT.glob("*/*/meta.json")):
        try:
            m = json.load(open(meta))
        except (OSError, ValueError):
            continue
        day = meta.parent.parent.name
        # Folders are named by the UTC date, as the recorder writes them.
        if only_today and day != datetime.now(timezone.utc).date().isoformat():
            continue
        segments.append((day, meta.parent, m))
    if not segments:
        print("\nno recordings yet.")
        return

    print("\nper day:")
    days = defaultdict(lambda: defaultdict(float))
    for day, _, m in segments:
        for key in ("seconds", "touching", "sliding", "twoFingers", "threeFingers", "palm", "keys"):
            days[day][key] += m.get(key, 0)
        days[day]["segments"] += 1
    for day, t in days.items():
        print(f"  {day}: {minutes(t['seconds'])} recorded in {int(t['segments'])} stretches. "
              f"one-finger slides {minutes(t['sliding'])}, two fingers {minutes(t['twoFingers'])}, "
              f"three {minutes(t['threeFingers'])}, palm {minutes(t['palm'])}, {int(t['keys'])} keys")

    print("\nquality (newest stretches):")
    for day, folder, m in segments[-5:]:
        emg, span = quality(folder)
        flag = "  <- weak radio" if 0 < emg < 1500 else "  <- no sEMG" if emg == 0 else ""
        print(f"  {day}/{folder.name}: {minutes(m.get('seconds', 0))}, sEMG for {minutes(span)} at {emg / 20.48:.0f}% of samples{flag}")

    directions = np.zeros(8)
    speeds, positions = [], []
    gestures = {2: 0, 3: 0}
    for _, folder, _ in segments:
        if (folder / "touches.bin").exists():
            d, s, p, g = segment_coverage(folder)
            directions += d
            speeds += s
            positions += p
            gestures[2] += g[2]
            gestures[3] += g[3]
    print("\ncoverage of one-finger slides:")
    total = directions.sum()
    if total > 0:
        for name, amount in zip(DIRECTIONS, directions):
            bar = "█" * int(round(40 * amount / directions.max()))
            print(f"  {name:10s} {minutes(amount):>12s} {bar}")
        weak = [n for n, a in zip(DIRECTIONS, directions) if a < 0.05 * total]
        if weak:
            print(f"  thin: {', '.join(weak)}")
        s = np.array(speeds)
        print(f"  speed: slow (<50 mm/s) {np.mean(s < 50):.0%}, medium {np.mean((s >= 50) & (s < 150)):.0%}, quick (150+) {np.mean(s >= 150):.0%}")
        p = np.array(positions)
        xs = np.linspace(p[:, 0].min(), p[:, 0].max(), 4)
        ys = np.linspace(p[:, 1].min(), p[:, 1].max(), 4)
        grid, _, _ = np.histogram2d(p[:, 0], p[:, 1], bins=[xs, ys])
        empty = int((grid < 0.02 * len(p)).sum())
        print(f"  trackpad area: {9 - empty} of 9 regions well covered")
    else:
        print("  none yet")
    print(f"\ngestures caught: {gestures[2]} two-finger, {gestures[3]} three-finger")


if __name__ == "__main__":
    main()
