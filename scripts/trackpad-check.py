#!/usr/bin/env python3
"""Tests whether a trackpad recording's sEMG predicts the finger on the trackpad.

    scripts/trackpad-check.py                  the newest trackpad recording
    scripts/trackpad-check.py RUN [RUN ...]    these recordings, trained and tested together
    scripts/trackpad-check.py --across [RUN ...]   train on every recording but the last, test on the last
    scripts/trackpad-check.py --across --last 3    the same, over the three newest recordings

A recording comes from "record trackpad" in a dev build (./scripts/build.sh --dev).
The first 70 % of the time trains simple models, the last 30 % tests them, so a
score says how well the band would do on movement it has not seen.
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfiltfilt
from sklearn.linear_model import LogisticRegression, Ridge
from sklearn.metrics import r2_score, roc_auc_score
from sklearn.preprocessing import StandardScaler

LAB = Path.home() / "Library/Application Support/Kinesis/Lab"
RATE = 2048
HOP = 0.02      # one prediction every 20 ms
WINDOW = 0.1    # from the last 100 ms of sEMG
CONTEXT = 5     # and the four windows before it


def varint(data, i):
    value, shift = 0, 0
    while True:
        byte = data[i]
        i += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, i
        shift += 7


def batch(payload):
    """EMGBatch: field 1 sequence, 2 band time in µs, 3 the 16 samples of 8 channels."""
    i, fields = 0, {}
    while i < len(payload):
        tag, i = varint(payload, i)
        number, kind = tag >> 3, tag & 7
        if kind == 0:
            fields[number], i = varint(payload, i)
        elif kind == 2:
            length, i = varint(payload, i)
            fields[number] = payload[i:i + length]
            i += length
        else:
            return None
    if 2 not in fields or not isinstance(fields.get(3), (bytes, bytearray)) or len(fields[3]) != 256:
        return None
    return fields[2], np.frombuffer(bytes(fields[3]), dtype="<u2").reshape(16, 8)


def band_clock(stamps, arrivals):
    """The shift from the band's clock to the Mac's, and which batches to keep.

    A batch's band time can be corrupt: one on 2026-09-25 was off by exactly 2^32 µs.
    Batches more than a second away from the typical shift are dropped, and the
    shift is the earliest arrival among the rest, the transit of an on-time batch.
    """
    shift = arrivals - stamps
    keep = np.abs(shift - np.median(shift)) < 1.0
    return np.min(shift[keep]), keep


def load_emg(path):
    """Samples on the Mac's clock: the band's clock, shifted by its smallest transit time."""
    stamps, arrivals, blocks = [], [], []
    for line in open(path):
        try:
            row = json.loads(line)
            decoded = batch(bytes.fromhex(row["payload"]))
        except (ValueError, KeyError):
            continue
        if decoded:
            stamps.append(decoded[0] / 1e6)
            arrivals.append(row["uptime"])
            blocks.append(decoded[1])
    if not blocks:
        sys.exit(f"no sEMG in {path}")
    stamps, arrivals = np.array(stamps), np.array(arrivals)
    offset, keep = band_clock(stamps, arrivals)
    blocks = [b for b, k in zip(blocks, keep) if k]
    stamps = stamps[keep]
    times = np.concatenate([s + offset + np.arange(16) / RATE for s in stamps])
    values = np.concatenate(blocks).astype(float)
    order = np.argsort(times, kind="stable")
    return times[order], values[order]


def features(times, values, grid):
    """Log RMS and waveform length per channel, over the window before each grid time."""
    filtered = sosfiltfilt(butter(4, [20, 450], btype="band", fs=RATE, output="sos"), values - values.mean(0), axis=0)
    squared = np.concatenate([np.zeros((1, 8)), np.cumsum(filtered ** 2, axis=0)])
    changes = np.concatenate([np.zeros((1, 8)), np.cumsum(np.abs(np.diff(filtered, axis=0, prepend=filtered[:1])), axis=0)])
    ends = np.searchsorted(times, grid)
    starts = np.searchsorted(times, grid - WINDOW)
    counts = np.maximum(1, ends - starts)[:, None]
    rms = np.log(np.sqrt((squared[ends] - squared[starts]) / counts) + 1e-3)
    length = np.log((changes[ends] - changes[starts]) / counts + 1e-3)
    frame = np.hstack([rms, length])
    stacked = [np.roll(frame, k, axis=0) for k in range(CONTEXT)]
    return np.hstack(stacked)


def load_touches(path, grid):
    """Contact, and the velocity of a single finger in mm/s, at each grid time."""
    rows = []
    for line in open(path):
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass
    rows = [r for r in rows if "id" in r]
    mm = 25.4 / 72
    # Where each finger is over time.
    active, track = {}, []
    for r in sorted(rows, key=lambda r: r["t"]):
        if r["phase"] in ("ended", "cancelled"):
            active.pop(r["id"], None)
        else:
            active[r["id"]] = (r["x"] * r["w"] * mm, r["y"] * r["h"] * mm)
        track.append((r["t"], dict(active)))
    times = np.array([t for t, _ in track])
    contact = np.zeros(len(grid), dtype=bool)
    single = np.full((len(grid), 2), np.nan)
    for k, t in enumerate(grid):
        i = np.searchsorted(times, t, side="right") - 1
        if i < 0:
            continue
        fingers = track[i][1]
        contact[k] = len(fingers) > 0
        if len(fingers) == 1:
            single[k] = next(iter(fingers.values()))
    velocity = np.full((len(grid), 2), np.nan)
    velocity[1:] = (single[1:] - single[:-1]) / HOP
    # Smooth over 60 ms; a gap or a finger change leaves no velocity.
    kernel = np.ones(3) / 3
    for axis in range(2):
        v = velocity[:, axis]
        ok = ~np.isnan(v)
        smooth = np.convolve(np.where(ok, v, 0), kernel, mode="same") / np.maximum(np.convolve(ok, kernel, mode="same"), 1e-9)
        velocity[:, axis] = np.where(np.convolve(~ok, np.ones(3), mode="same") > 0, np.nan, smooth)
    return contact, velocity


def recording(folder):
    emg_times, values = load_emg(folder / "emg.jsonl")
    cues = [json.loads(l) for l in open(folder / "cues.jsonl") if l.strip()]
    start = cues[0]["start"] if cues else emg_times[0] + 1
    end = cues[-1]["end"] if cues else emg_times[-1]
    grid = np.arange(max(start, emg_times[0] + WINDOW * CONTEXT), min(end, emg_times[-1]), HOP)
    x = features(emg_times, values, grid)
    contact, velocity = load_touches(folder / "touches.jsonl", grid)
    return grid, x, contact, velocity, emg_times, values


def long_enough(folder):
    """A finished recording of two minutes or more. Shorter ones were stopped early."""
    try:
        return json.load(open(folder / "summary.json"))["seconds"] >= 120 and (folder / "emg.jsonl").exists()
    except (OSError, ValueError, KeyError):
        return False


def main():
    arguments = sys.argv[1:]
    across = "--across" in arguments
    arguments = [a for a in arguments if a != "--across"]
    runs = sorted(p for p in LAB.glob("*-trackpad") if long_enough(p))
    if arguments[:1] == ["--last"]:
        folders = runs[-int(arguments[1]):]
    elif arguments:
        folders = [Path(a).expanduser() for a in arguments]
    else:
        if not runs:
            sys.exit("no trackpad recordings yet")
        folders = runs[-2:] if across else [runs[-1]]
    if across and len(folders) < 2:
        sys.exit("--across needs two recordings or more")
    parts = [recording(f) for f in folders]
    for f, (grid, x, contact, velocity, emg_times, values) in zip(folders, parts):
        seconds = emg_times[-1] - emg_times[0]
        print(f"{f.name}: {seconds:.0f} s of sEMG at {len(emg_times) / seconds:.0f} samples/s, "
              f"finger down {contact.mean() * 100:.0f} % of the time, "
              f"single-finger velocity for {np.isfinite(velocity[:, 0]).mean() * 100:.0f} %")
    if across:
        # Train on the earlier wearings, test on the last: a new wearing the model never saw.
        train = [np.full(len(p[0]), k < len(parts) - 1) for k, p in enumerate(parts)]
        print(f"\ntrained on {len(parts) - 1} recording(s), tested on {folders[-1].name}")
    else:
        # Train on the first 70 % of each recording, test on the rest.
        train = [np.arange(len(p[0])) < 0.7 * len(p[0]) for p in parts]
    # Each wearing sits differently on the skin, so each recording's features are scaled
    # by its own averages. The band could learn those in its first minute of wear.
    x = np.vstack([StandardScaler().fit_transform(p[1]) for p in parts])
    contact = np.concatenate([p[2] for p in parts])
    velocity = np.vstack([p[3] for p in parts])
    fit = np.concatenate(train)
    test = ~fit
    scale = StandardScaler().fit(x[fit])
    x = scale.transform(x)

    print("\ncan it tell a finger on the trackpad from a lifted one?")
    if contact[fit].all() or not contact[fit].any():
        print("  not enough of both in the training part")
    else:
        model = LogisticRegression(max_iter=2000, C=0.5).fit(x[fit], contact[fit])
        auc = roc_auc_score(contact[test], model.predict_proba(x[test])[:, 1])
        print(f"  score {auc:.2f}  (0.5 is chance, 1.0 is perfect)")

    moving = np.isfinite(velocity[:, 0])
    print("\ncan it tell how the finger slides?")
    for axis, name in ((0, "left-right"), (1, "up-down")):
        ok_fit, ok_test = fit & moving, test & moving
        if ok_fit.sum() < 200 or ok_test.sum() < 100:
            print(f"  {name}: not enough sliding")
            continue
        model = Ridge(alpha=10).fit(x[ok_fit], velocity[ok_fit, axis])
        guess = model.predict(x[ok_test])
        truth = velocity[ok_test, axis]
        r2 = r2_score(truth, guess)
        corr = np.corrcoef(truth, guess)[0, 1]
        fast = np.abs(truth) > 20
        sign = (np.sign(guess[fast]) == np.sign(truth[fast])).mean() if fast.any() else float("nan")
        print(f"  {name}: variance explained {max(r2, 0) * 100:.0f} %, correlation {corr:.2f}, "
              f"direction right {sign * 100:.0f} % of the time on moves over 20 mm/s (50 % is chance)")
    speed = np.hypot(velocity[:, 0], velocity[:, 1])
    ok_fit, ok_test = fit & moving, test & moving
    if ok_fit.sum() >= 200 and ok_test.sum() >= 100:
        model = Ridge(alpha=10).fit(x[ok_fit], speed[ok_fit])
        corr = np.corrcoef(speed[ok_test], model.predict(x[ok_test]))[0, 1]
        print(f"  speed alone: correlation {corr:.2f}")


if __name__ == "__main__":
    main()
