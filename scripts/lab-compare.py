#!/usr/bin/env python3
"""Compares practice lab runs side by side.

    scripts/lab-compare.py                 the newest run of each mode
    scripts/lab-compare.py RUN RUN ...     these run folders, in this order
    scripts/lab-compare.py --last 6        the six newest runs

Runs live in ~/Library/Application Support/Kinesis/Lab. A run comes from the lab
screen in a build made with KINESIS_LAB=1 ./scripts/build.sh.
"""
import bisect
import json
import math
import sys
from pathlib import Path

LAB = Path.home() / "Library/Application Support/Kinesis/Lab"


def median(values):
    values = sorted(v for v in values if v is not None)
    return values[len(values) // 2] if values else None


def span(values):
    values = sorted(values)
    if len(values) < 10:
        return None
    return values[int(0.95 * (len(values) - 1))] - values[int(0.05 * (len(values) - 1))]


def forearm(q):
    """Compass angle (left is positive) and elevation, as ForearmAim computes them."""
    w, x, y, z = q
    vx, vy, vz = 2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)
    return math.degrees(math.atan2(vy, vx)), math.degrees(math.asin(max(-1, min(1, vz))))


def screen_degrees(reach, azimuth, elevation):
    """PointerReach.screenDegrees: right and down."""
    up_tilt, across_tilt = reach.get("upTilt", 0), reach.get("acrossTilt", 0)
    scale = 1 + up_tilt * across_tilt
    right = -(azimuth - up_tilt * elevation) / scale
    up = (across_tilt * azimuth + elevation) / scale
    return right, -up


def speed_of(summary):
    """Points per degree of arm turn. Early runs scaled the reach to the display instead."""
    if "speed" in summary:
        return summary["speed"]
    if "reach" in summary and "display" in summary:
        return summary["display"][0] / summary["reach"]["degreesAcrossWidth"] * summary.get("sensitivity", 1)
    return None


def load(folder):
    lines = lambda name: [json.loads(line) for line in open(folder / name) if line.strip()]
    summary = json.load(open(folder / "summary.json")) if (folder / "summary.json").exists() else {}
    trials = lines("trials.jsonl") if (folder / "trials.jsonl").exists() else []
    pointer = lines("pointer.jsonl") if (folder / "pointer.jsonl").exists() else []
    aims = []
    if (folder / "motion.jsonl").exists():
        last = None
        for row in lines("motion.jsonl"):
            if row.get("event") != "quat":
                continue
            azimuth, elevation = forearm(row["v"])
            if last is not None:
                azimuth = last + math.remainder(azimuth - last, 360)
            last = azimuth
            aims.append((row["at"], azimuth, elevation))
    return summary, trials, pointer, aims


def measure(folder):
    summary, trials, pointer, aims = load(folder)
    mode = summary.get("mode") or (trials[0]["mode"] if trials else "?")
    hits = [t for t in trials if t["hit"]]
    result = {
        "run": folder.name,
        "mode": mode,
        "calibrated": {True: "yes", False: "no"}.get(summary.get("calibrated"), "?"),
        "speed pt/°": speed_of(summary),
        "flick boost": summary.get("flickBoost"),
        "hits": "%d of %d" % (len(hits), len(trials)),
        "typical time s": median(t["seconds"] for t in hits),
        "typical miss pt": median(t.get("error") for t in trials),
        "straightness %": (lambda m: m * 100 if m is not None else None)(
            median(min(1, t["distance"] / t["pathLength"]) for t in hits if t["pathLength"] > 0)),
    }
    times = [p["t"] for p in pointer]

    def path(start, end):
        return pointer[bisect.bisect_left(times, start):bisect.bisect_right(times, end)]

    if mode == "targets":
        overshoots = []
        for t in trials:
            dx, dy = t["target"][0] - t["from"][0], t["target"][1] - t["from"][1]
            distance = math.hypot(dx, dy)
            if distance < 1:
                continue
            reach_along = max(((p["x"] - t["from"][0]) * dx + (p["y"] - t["from"][1]) * dy) / distance
                              for p in path(t["spawnedAt"], t["endedAt"])) if path(t["spawnedAt"], t["endedAt"]) else distance
            overshoots.append((max(0, reach_along - distance), t["radius"]))
        result["typical overshoot pt"] = median(o for o, _ in overshoots)
        result["overshoots past edge"] = "%d of %d" % (sum(o > r for o, r in overshoots), len(overshoots))
        for radius in (40, 24, 14):
            sized = [t for t in trials if round(t["radius"]) == radius]
            result["hits, %d pt" % radius] = "%d of %d" % (sum(t["hit"] for t in sized), len(sized))
    if mode == "moving":
        for index, speed in enumerate((180, 280, 400)):
            paced = [t for t in trials if t["index"] % 3 == index]
            result["hits, %d pt/s" % speed] = "%d of %d" % (sum(t["hit"] for t in paced), len(paced))
    if mode == "drag":
        result["typical grab miss pt"] = median(t.get("grabError") for t in trials)
        result["typical pinches"] = median(t.get("attempts") for t in trials)

    # How far the pointer and the arm drifted apart, after the first 5 seconds.
    if aims and pointer and "reach" in summary and "display" in summary:
        reach = summary["reach"]
        width, height = summary["display"]
        speed = speed_of(summary)
        scale = (speed, speed) if "speed" in summary else (
            width / reach["degreesAcrossWidth"] * summary.get("sensitivity", 1),
            height / reach["degreesAcrossHeight"] * summary.get("sensitivity", 1))
        aim_times = [a[0] for a in aims]
        start = pointer[0]["t"] + 5
        across, down = [], []
        for p in pointer[::4]:
            if p["t"] < start:
                continue
            i = bisect.bisect_right(aim_times, p["t"]) - 1
            if i < 0:
                continue
            arm = screen_degrees(reach, aims[i][1], aims[i][2])
            across.append(p["x"] / scale[0] - arm[0])
            down.append(p["y"] / scale[1] - arm[1])
        a, d = span(across), span(down)
        result["drift °"] = "%.0f×%.0f" % (a, d) if a is not None and d is not None else None
    return result


def main():
    arguments = sys.argv[1:]
    runs = sorted((p for p in LAB.iterdir() if p.is_dir()), key=lambda p: p.name) if LAB.exists() else []
    if arguments[:1] == ["--last"]:
        folders = runs[-int(arguments[1]):]
    elif arguments:
        folders = [Path(a).expanduser() for a in arguments]
    else:
        newest = {}
        for run in runs:
            newest[run.name.rsplit("-", 1)[-1]] = run
        folders = sorted(newest.values(), key=lambda p: p.name)
    if not folders:
        sys.exit("no lab runs yet")
    results = [measure(f) for f in folders]
    keys = []
    for r in results:
        keys += [k for k in r if k not in keys]
    width = max(len(k) for k in keys)
    column = max(20, max(len(r["run"]) for r in results) + 2)

    def cell(value):
        if value is None:
            return "-"
        return ("%.2f" % value if abs(value) < 10 else "%.0f" % value) if isinstance(value, float) else str(value)

    for key in keys:
        print(key.ljust(width + 2) + "".join(cell(r.get(key)).ljust(column) for r in results))


if __name__ == "__main__":
    main()
