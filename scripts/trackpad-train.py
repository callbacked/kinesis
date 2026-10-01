#!/usr/bin/env python3
"""Trains the live trackpad decoder and exports it for Kinesis.

    scripts/trackpad-train.py              every "record while I work" recording
    scripts/trackpad-train.py --fixture    also rewrites the Swift tests' fixtures
    scripts/trackpad-train.py --out PATH   exports somewhere else than the Lab folder

Every feature uses only past data, exactly as Kinesis computes it live. Per band, the
8 x 8 channel covariance over the last 160 ms is re-centered on a running average of
this wearing's covariances, then mapped to a flat space (the Riemannian tangent space).
That re-centering carries a model from one wearing to the next. The band's gyro joins
it: a slide rocks the wrist a little. A small network reads the newest frame and the
ones 80 and 160 ms before it, and the gyro over the last 180 ms.

Inside Kinesis, the network then keeps learning from the Mac's trackpad on each wearing
(LiveTrackpad.swift). Before exporting, this prints how the recipe scores on the newest
day's last 30 %, never trained on: fresh, and after 2 and 10 minutes of that learning.
The model goes to ~/Library/Application Support/Kinesis/Lab/decoder.json, where a dev
build picks it up. Needs PyTorch.
"""
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfilt
from scipy.signal import lfilter
from sklearn.metrics import roc_auc_score

here = Path(__file__).parent
spec = importlib.util.spec_from_file_location("check", here / "trackpad-check.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

RATE = 2048
HOP = 41              # samples per feature frame, about 20 ms
BANDS = [(20, 60), (60, 120), (120, 250), (250, 450)]
CONTEXT = 10          # frames: the last 200 ms
FLOOR = 1e-2


def sos_for(low, high):
    return butter(2, [low, high], btype="band", fs=RATE, output="sos")


def frames(values):
    """Log power per band and channel over each block of HOP samples, from past samples only."""
    centered = values - values[:RATE].mean(0)          # the first second sets the offset
    blocks = len(centered) // HOP
    out = []
    for low, high in BANDS:
        band = sosfilt(sos_for(low, high), centered, axis=0)[:blocks * HOP]
        power = (band ** 2).reshape(blocks, HOP, 8).mean(1)
        out.append(np.log(power + FLOOR))
    return np.hstack(out)                                # blocks x 32


def stack(frame):
    return np.hstack([np.roll(frame, k, axis=0) for k in range(CONTEXT)])


def prepare(folder):
    emg_times, values = check.load_emg(folder / "emg.jsonl")
    frame = frames(values)
    times = emg_times[np.arange(len(frame)) * HOP + HOP - 1]
    cues = [json.loads(l) for l in open(folder / "cues.jsonl") if l.strip()]
    keep = (times >= cues[0]["start"]) & (times <= cues[-1]["end"]) if cues else np.ones(len(times), bool)
    keep[:CONTEXT] = False
    contact, velocity = check.load_touches(folder / "touches.jsonl", times)
    return {"name": folder.name, "frame": frame, "values": values, "keep": keep, "contact": contact, "velocity": velocity,
            "wearing": folder.name}


# Passive recordings: binary files from "record while I work".
PALM_SIZE = 2.0        # MultitouchSupport contact size: a fingertip stays under this
TOUCHING = (3, 4)      # contact states, as seen on a real trackpad: 1 in range, 2 hovering,
                       # 3 making touch, 4 touching, 5 breaking touch, 6 lingering, 7 out of range


def read_emg_bin(path):
    raw = np.fromfile(path, dtype=np.dtype([("arrival", "<f8"), ("band", "<u8"), ("sequence", "<u8"), ("values", "<u2", (16, 8))]))
    stamps, arrivals = raw["band"] / 1e6, raw["arrival"]
    offset, keep = check.band_clock(stamps, arrivals)
    raw, stamps = raw[keep], stamps[keep]
    times = (stamps[:, None] + offset + np.arange(16)[None, :] / RATE).reshape(-1)
    if not len(times):
        raise ValueError(f"no sEMG in {path}")
    values = raw["values"].reshape(-1, 8)              # 16-bit integers: exact, and a quarter of float64
    order = np.argsort(times, kind="stable")
    return times[order], values[order]


def frame_count(values):
    """How many frames a recording makes. Live features are computed later, so only the count is needed here."""
    return np.empty((len(values) // HOP, 0), np.float32)


def read_touches_bin(path):
    """Frames of (time on the Mac's clock, [(id, state, size, x mm, y mm)])."""
    data = open(path, "rb").read()
    frames, i = [], 0
    while i + 20 <= len(data):
        stamp, arrival = np.frombuffer(data, "<f8", 2, i)
        count = int(np.frombuffer(data, "<i4", 1, i + 16)[0])
        i += 20
        contacts = []
        for k in range(count):
            c = data[i + 96 * k:i + 96 * (k + 1)]
            if len(c) < 96:
                break
            ident, state = np.frombuffer(c, "<i4", 2, 16)
            size = np.frombuffer(c, "<f4", 1, 48)[0]
            mm = np.frombuffer(c, "<f4", 2, 68)
            contacts.append((int(ident), int(state), float(size), float(mm[0]), float(mm[1])))
        i += 96 * count
        frames.append((stamp, arrival, contacts))
    if not frames:
        return []
    # The framework's clock runs about 1.2 % slow against the Mac's (0.988 in every
    # recording on 2026-09-25), so a fixed offset drifts seconds off over a stretch.
    # Fit a rate and an offset, then move the line down to the quickest arrivals.
    stamps = np.array([f[0] for f in frames])
    arrivals = np.array([f[1] for f in frames])
    rate, offset = np.polyfit(stamps - stamps[0], arrivals, 1)
    fitted = offset + rate * (stamps - stamps[0])
    late = arrivals - fitted
    # The rate also wanders a little: up to about 110 ms over half an hour. So the line
    # is corrected every 30 s, by that stretch's quickest arrivals.
    edges = np.arange(stamps[0], stamps[-1] + 30, 30)
    centers, floors = [], []
    for lo, hi in zip(edges, edges[1:]):
        inside = (stamps >= lo) & (stamps < hi)
        if inside.sum() >= 20:
            centers.append(stamps[inside].mean())
            floors.append(np.percentile(late[inside], 2))
    correction = np.interp(stamps, centers, floors) if centers else np.full(len(stamps), np.percentile(late, 2))
    times = fitted + correction
    return [(time, contacts) for time, (_, _, contacts) in zip(times, frames)]


def prepare_passive(folder):
    emg_times, values = read_emg_bin(folder / "emg.bin")
    frame = frame_count(values)
    times = emg_times[np.arange(len(frame)) * HOP + HOP - 1]
    touch_frames = read_touches_bin(folder / "touches.bin")
    stamps = np.array([t for t, _ in touch_frames]) if touch_frames else np.zeros(0)
    contact = np.zeros(len(times), bool)
    single = np.full((len(times), 2), np.nan)
    keep = np.ones(len(times), bool)
    for k, t in enumerate(times):
        j = np.searchsorted(stamps, t, side="right") - 1
        if j < 0 or t - stamps[j] > 0.5:
            continue                                   # no frame lately: nothing on the trackpad
        touching = [c for c in touch_frames[j][1] if c[1] in TOUCHING]
        fingers = [c for c in touching if c[2] < PALM_SIZE]
        if len(fingers) < len(touching):
            keep[k] = False                            # a palm is down: leave the moment out
            continue
        contact[k] = bool(fingers)
        if len(fingers) == 1:
            single[k] = fingers[0][3:5]
    # Over the real time between frames. Across a gap in the sEMG, as when the radio drops
    # batches, there is no velocity, as live labeling does it.
    velocity = np.full((len(times), 2), np.nan)
    dt = np.diff(times)
    velocity[1:] = (single[1:] - single[:-1]) / dt[:, None]
    velocity[1:][dt > 1.5 * HOP / RATE] = np.nan
    # A mouse moved the pointer: the hand was busy, but not on a trackpad. Leave it out.
    pointer = folder / "pointer.bin"
    if pointer.exists() and pointer.stat().st_size:
        moves = np.fromfile(pointer, dtype="<f8")
        # Only moves well away from any trackpad contact: a touch's own first moves race the log.
        touched = np.array([t for t, c in touch_frames if any(x[1] in TOUCHING for x in c)])
        if len(touched):
            gap = np.abs(touched[np.clip(np.searchsorted(touched, moves), 0, len(touched) - 1)] - moves)
            gap = np.minimum(gap, np.abs(touched[np.clip(np.searchsorted(touched, moves) - 1, 0, len(touched) - 1)] - moves))
            moves = moves[gap > 0.3]
        near = np.searchsorted(moves, times - 1.0) < np.searchsorted(moves, times + 1.0)
        keep &= ~near
    keep[:CONTEXT] = False
    try:
        wearing = f"{folder.parent.name} wearing {json.load(open(folder / 'meta.json'))['wearing']}"
    except (OSError, ValueError, KeyError):
        wearing = folder.parent.name + "/" + folder.name
    return {"name": "passive " + folder.parent.name + "/" + folder.name, "frame": frame, "values": values, "keep": keep,
            "contact": contact, "velocity": velocity, "wearing": wearing, "gyro": gyro_for(folder, len(frame))}


def passive_segments(minimum=20):
    out = []
    for meta in sorted(check.LAB.glob("passive/*/*/meta.json")):
        try:
            if json.load(open(meta))["seconds"] >= minimum:
                out.append(meta.parent)
        except (OSError, ValueError, KeyError):
            pass
    return out


def desk_sessions(minimum=20):
    """Finger cursor sessions on a desk, from Lab/desk: sEMG, gyro, and when Control was held."""
    out = []
    for meta in sorted(check.LAB.glob("desk/*/meta.json")):
        try:
            if json.load(open(meta))["seconds"] >= minimum and (meta.parent / "clutch.bin").stat().st_size:
                out.append(meta.parent)
        except (OSError, ValueError, KeyError):
            pass
    return out


def prepare_desk(folder):
    """Sure touches only: a fingertip is on the desk while Control is held. A released key
    doesn't prove the finger left the desk, so those frames are left out, as are the 100 ms
    around each press. No velocity, so these frames never teach direction."""
    emg_times, values = read_emg_bin(folder / "emg.bin")
    frame = frame_count(values)
    times = emg_times[np.arange(len(frame)) * HOP + HOP - 1]
    clutch = np.fromfile(folder / "clutch.bin", dtype=np.dtype([("time", "<f8"), ("held", "u1")]))
    index = np.searchsorted(clutch["time"], times, side="right") - 1
    contact = np.where(index >= 0, clutch["held"][np.maximum(index, 0)] == 1, False)
    near = np.zeros(len(times), bool)
    for t in clutch["time"]:
        near |= np.abs(times - t) < 0.1
    keep = contact & ~near
    keep[:CONTEXT] = False
    return {"name": "desk " + folder.name.replace("T", "/", 1), "frame": frame, "values": values, "keep": keep,
            "contact": contact, "velocity": np.full((len(times), 2), np.nan), "wearing": "desk " + folder.name,
            "gyro": gyro_for(folder, len(frame))}


# The live recipe. TrackpadDecoder.swift computes the same, step for step.
WINDOW = 8            # frames per covariance: 160 ms
LAGS = (0, 4, 8)      # the network sees now, 80 ms ago, and 160 ms ago
SHRINK = 1e-3         # adds this share of the average variance to the diagonal
ADAPT = 60.0          # seconds the running reference averages over
PAIRS = np.triu_indices(8)
PAIR_WEIGHT = np.where(PAIRS[0] == PAIRS[1], 1.0, np.sqrt(2))
VELOCITY_SCALE = 100.0  # the network's velocity output is in units of 100 mm/s
GYRO_LAGS = 9         # the gyro from now and each of the 8 frames before
GYRO_SCALE = 300.0    # raw counts; a slide rocks the wrist by tens to hundreds


def eigen_map(m, function):
    """function applied to a symmetric matrix's eigenvalues."""
    w, v = np.linalg.eigh(m)
    return (v * function(w)[..., None, :]) @ np.swapaxes(v, -1, -2)


def covariances(values):
    """Per frame and band: the channel covariance over the last WINDOW frames, from past samples only."""
    centered = values - values[:16].mean(0)              # the first batch sets the offset, as live
    blocks = len(centered) // HOP
    out = np.empty((blocks, len(BANDS), 8, 8))
    counts = np.minimum(np.arange(blocks) + 1, WINDOW)[:, None, None] * HOP
    for b, (low, high) in enumerate(BANDS):
        y = sosfilt(sos_for(low, high), centered, axis=0)[:blocks * HOP].reshape(blocks, HOP, 8)
        per = np.einsum("bhi,bhj->bij", y, y)
        window = per.copy()
        for k in range(1, WINDOW):
            window[k:] += per[:-k]
        cov = window / counts
        cov += SHRINK * np.trace(cov, axis1=1, axis2=2)[:, None, None] / 8 * np.eye(8)
        out[:, b] = cov
    return out


def log_covariances(cov):
    return eigen_map(cov, lambda w: np.log(np.maximum(w, 1e-12)))


def tangent(cov, log_cov, reference, adapt=ADAPT):
    """Re-centers each frame on a running mean of log covariances that starts at `reference`,
    then maps it to the tangent space: frames x (bands x 36)."""
    flat = log_cov.reshape(len(log_cov), -1)
    if adapt > 0:
        rate = 1 / (adapt * RATE / HOP)
        mean, _ = lfilter([rate], [1, rate - 1], flat, axis=0, zi=(1 - rate) * np.tile(reference.reshape(-1), (1, 1)))
    else:
        mean = np.tile(reference.reshape(-1), (len(flat), 1))
    mean = mean.reshape(log_cov.shape)
    whiten = eigen_map(mean, lambda w: np.exp(-0.5 * w))
    centered = log_covariances(whiten @ cov @ whiten)
    return (centered[:, :, PAIRS[0], PAIRS[1]] * PAIR_WEIGHT).reshape(len(cov), -1)


def gyro_features(emg_band, emg_arrival, gyro_band, gyro_arrival, gyro_values, n_frames):
    """Per frame: the newest gyro sample the Mac had when the frame's sEMG arrived, sampled no
    later than the frame's end, less its running average, for now and the 8 frames before.
    Live, a frame ends before its gyro can arrive, so training sees only what live sees.
    Band times in seconds; emg_* per batch, in order. Frames before any gyro read zero."""
    band = (emg_band[:, None] + np.arange(16)[None] / RATE).reshape(-1)
    arrival = np.repeat(emg_arrival, 16)
    ends = np.arange(n_frames) * HOP + HOP - 1
    frame_band, frame_arrival = band[ends], arrival[ends]
    order = np.argsort(gyro_band, kind="stable")
    gyro_band, gyro_arrival, gyro_values = gyro_band[order], gyro_arrival[order], gyro_values[order]
    # Of the samples received by then and sampled by the frame's end, the newest. Radio
    # batches can arrive out of order, so look back up to 32 samples, a quarter second.
    newest = np.searchsorted(gyro_band, frame_band, side="right") - 1
    index = np.full(n_frames, -1)
    for back in range(32):
        candidate = newest - back
        ok = (index < 0) & (candidate >= 0)
        ok[ok] &= gyro_arrival[candidate[ok]] <= frame_arrival[ok]
        index[ok] = candidate[ok]
    out = np.zeros((n_frames, 3))
    rate = 1 / (ADAPT * RATE / HOP)
    mean = None
    for k in np.flatnonzero(index >= 0):
        v = gyro_values[index[k]]
        mean = v.copy() if mean is None else mean + rate * (v - mean)
        out[k] = (v - mean) / GYRO_SCALE
    return np.hstack([np.vstack([np.zeros((k, 3)), out[:n_frames - k]]) for k in range(GYRO_LAGS)])


def gyro_for(folder, n_frames):
    raw = np.fromfile(folder / "emg.bin", dtype=np.dtype([("arrival", "<f8"), ("band", "<u8"), ("sequence", "<u8"), ("values", "<u2", (16, 8))]))
    stamps = raw["band"] / 1e6
    _, keep = check.band_clock(stamps, raw["arrival"])
    raw, stamps = raw[keep], stamps[keep]
    order = np.argsort(stamps, kind="stable")
    g = np.fromfile(folder / "gyro.bin", dtype=np.dtype([("arrival", "<f8"), ("band", "<u8"), ("values", "<f8", (3,))])) \
        if (folder / "gyro.bin").exists() else np.zeros(0, dtype=np.dtype([("arrival", "<f8"), ("band", "<u8"), ("values", "<f8", (3,))]))
    gb = g["band"] / 1e6
    shift = g["arrival"] - gb
    good = np.abs(shift - np.median(shift)) < 1.0 if len(g) else np.zeros(0, bool)
    return gyro_features(stamps[order], raw["arrival"][order], gb[good], g["arrival"][good], g["values"][good], n_frames)


def lagged(features):
    return np.hstack([np.roll(features, k, axis=0) for k in LAGS])


def reference_for(recordings):
    """The average log covariance over the training wearings: where a new wearing starts."""
    return np.mean([log_covariances(covariances(r["values"])).mean(0) for r in recordings], axis=0)


def featurize(r, reference):
    cov = covariances(r["values"])[:len(r["frame"])]
    return np.hstack([lagged(tangent(cov, log_covariances(cov), reference)), r["gyro"]]).astype(np.float32)


def train_network(x, contact, velocity, weight, epochs=12, seed=0):
    import torch
    torch.manual_seed(seed)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    mean, std = x.mean(0), x.std(0) + 1e-6
    X = torch.tensor((x - mean) / std, dtype=torch.float32)
    C = torch.tensor(contact, dtype=torch.float32)
    V = torch.tensor(np.nan_to_num(velocity / VELOCITY_SCALE), dtype=torch.float32)
    M = torch.tensor(np.isfinite(velocity[:, 0]), dtype=torch.float32)
    W = torch.tensor(weight / weight.mean(), dtype=torch.float32)
    net = torch.nn.Sequential(torch.nn.Linear(x.shape[1], 256), torch.nn.GELU(), torch.nn.Dropout(0.3),
                              torch.nn.Linear(256, 128), torch.nn.GELU(), torch.nn.Dropout(0.3),
                              torch.nn.Linear(128, 3)).to(device)
    optimizer = torch.optim.AdamW(net.parameters(), 1e-3, weight_decay=1e-2)
    for _ in range(epochs):
        net.train()
        for batch in torch.randperm(len(X)).split(1024):
            xb, cb, vb, mb, wb = (a[batch].to(device) for a in (X, C, V, M, W))
            out = net(xb + 0.1 * torch.randn_like(xb))
            touch = torch.nn.functional.binary_cross_entropy_with_logits(out[:, 0], cb, reduction="none")
            slide = torch.nn.functional.huber_loss(out[:, 1:], vb, reduction="none").sum(1) * mb
            loss = ((touch + 2 * slide) * wb).mean()
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
    net.eval().cpu()
    layers = [m for m in net if isinstance(m, torch.nn.Linear)]
    return {"inputMean": mean.tolist(), "inputStd": std.tolist(),
            "layers": [{"weights": l.weight.detach().double().numpy().tolist(), "bias": l.bias.detach().double().numpy().tolist()}
                       for l in layers]}


# Learning inside Kinesis: LiveTrackpad.swift fine-tunes the whole network on the current
# wearing's trackpad-labeled frames with TrackpadFineTune.swift, which computes this.
FINE_TUNE = {"epochs": 4, "rate": 3e-4, "batch": 256, "noise": 0.1, "anchor": 1e-3}


def fine_tune(network, x, contact, velocity, epochs=4, rate=3e-4, batch=256, noise=0.1, anchor=1e-3, shuffle=True, seed=0):
    """The exported network, fine-tuned on scaled features x. Returns a network like it."""
    import torch
    torch.manual_seed(seed)
    layers = [torch.nn.Linear(len(l["weights"][0]), len(l["weights"])) for l in network["layers"]]
    for linear, l in zip(layers, network["layers"]):
        linear.weight.data = torch.tensor(l["weights"], dtype=torch.float32)
        linear.bias.data = torch.tensor(l["bias"], dtype=torch.float32)
    params = [p for l in layers for p in (l.weight, l.bias)]
    home = [p.detach().clone() for p in params]
    X = torch.tensor(x, dtype=torch.float32)
    C = torch.tensor(contact, dtype=torch.float32)
    V = torch.tensor(np.nan_to_num(velocity / VELOCITY_SCALE), dtype=torch.float32)
    M = torch.tensor(np.isfinite(velocity[:, 0]), dtype=torch.float32)
    optimizer = torch.optim.Adam(params, rate)
    for _ in range(epochs):
        order = torch.randperm(len(X)) if shuffle else torch.arange(len(X))
        for rows in order.split(batch):
            h = X[rows] + noise * torch.randn(len(rows), X.shape[1]) if noise else X[rows]
            for k, linear in enumerate(layers):
                h = linear(h)
                if k < len(layers) - 1:
                    h = torch.nn.functional.gelu(h)
            loss = (torch.nn.functional.binary_cross_entropy_with_logits(h[:, 0], C[rows], reduction="none")
                    + 2 * torch.nn.functional.huber_loss(h[:, 1:], V[rows], reduction="none").sum(1) * M[rows]).mean()
            loss = loss + anchor * sum(((p - q) ** 2).sum() for p, q in zip(params, home))
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
    return {**network, "layers": [{"weights": l.weight.detach().double().numpy().tolist(), "bias": l.bias.detach().double().numpy().tolist()}
                                  for l in layers]}


def write_fine_tune_fixture(path):
    """A small network, labeled examples, and fine_tune's result without noise or shuffling,
    for TrackpadDecoderTests to check TrackpadFineTune.swift step for step."""
    rng = np.random.default_rng(11)
    sizes = ((20, 8), (8, 6), (6, 3))
    network = {"layers": [{"weights": (rng.normal(size=(o, i)) / np.sqrt(i)).tolist(), "bias": (rng.normal(size=o) * 0.1).tolist()}
                          for i, o in sizes]}
    x = rng.normal(size=(150, 20))
    contact = rng.random(150) < 0.5
    velocity = np.where((rng.random(150) < 0.5)[:, None], rng.normal(size=(150, 2)) * 120, np.nan)
    tuned = fine_tune(network, x, contact, velocity, epochs=3, rate=1e-2, batch=64, noise=0, anchor=1e-2, shuffle=False)
    path.write_text(json.dumps({"start": network, "tuned": tuned, "features": x.tolist(), "contact": contact.tolist(),
                                "velocity": np.nan_to_num(velocity / VELOCITY_SCALE, nan=1e9).tolist(),
                                "settings": {"epochs": 3, "rate": 1e-2, "batch": 64, "anchor": 1e-2}}))
    print(f"wrote {path}")


# Clicks: a deliberate raise of the index or middle finger. A small network of its own
# reads the same scaled features. It is not fine-tuned inside Kinesis: trackpad use only
# ever shows "not a raise", which would train raises out.
RAISE_THRESHOLD = 0.98
RAISE_LOCKOUT = 15    # frames after a click before another: 300 ms


def raise_sessions(minimum=60):
    """Recordings from "record finger raises", in Lab/raises."""
    out = []
    for meta in sorted(check.LAB.glob("raises/*/meta.json")):
        try:
            if json.load(open(meta))["seconds"] >= minimum and (meta.parent / "cues.bin").exists():
                out.append(meta.parent)
        except (OSError, ValueError, KeyError):
            pass
    return out


def prepare_raises(folder):
    """Per frame: 1 from 140 to 900 ms after a raise word lit up, 0 after a rest word and
    while the word was dim, NaN otherwise."""
    emg_times, values = read_emg_bin(folder / "emg.bin")
    frame = frame_count(values)
    times = emg_times[np.arange(len(frame)) * HOP + HOP - 1]
    cues = np.fromfile(folder / "cues.bin", dtype=np.dtype([("time", "<f8"), ("kind", "u1")]))
    label = np.full(len(frame), np.nan)
    trial = np.full(len(frame), -1)
    for n, cue in enumerate(cues):
        i = np.searchsorted(times, cue["time"])
        label[i + 7:i + 45] = 1.0 if cue["kind"] > 0 else 0.0
        trial[i + 7:i + 45] = n
        label[max(0, i - 40):max(0, i - 5)] = 0.0
        trial[max(0, i - 40):max(0, i - 5)] = n
    label[:CONTEXT] = np.nan
    return {"name": "raises " + folder.name.replace("T", "/", 1), "frame": frame, "values": values,
            "gyro": gyro_for(folder, len(frame)), "raise": label, "trial": trial, "cues": cues}


def raise_negatives(r, features):
    """Normal use, from a passive recording: never a deliberate raise. The half second around
    each lift off the trackpad counts three times, since a casual lift looks most like a raise."""
    contact = r["contact"]
    lifts = np.flatnonzero(contact[:-1] & ~contact[1:]) + 1
    near = np.zeros(len(contact), bool)
    for k in range(-25, 26):
        near[np.clip(lifts + k, 0, len(contact) - 1)] = True
    keep = r["keep"]
    other = np.flatnonzero(keep & ~near)[::8]
    return np.vstack([features[keep & near], features[other]]), np.r_[np.full((keep & near).sum(), 3.0), np.ones(len(other))]


def train_raise(network, positives, negatives, negative_weight, seed=0):
    """The raise detector, on features scaled as the main network scales them. Positives
    weigh as much in all as half the negatives."""
    import torch
    torch.manual_seed(seed)
    mean, std = np.array(network["inputMean"]), np.array(network["inputStd"])
    x = np.vstack([positives, negatives])
    y = np.r_[np.ones(len(positives)), np.zeros(len(negatives))]
    w = np.r_[np.full(len(positives), 0.5 * negative_weight.sum() / max(1, len(positives))), negative_weight]
    X = torch.tensor((x - mean) / std, dtype=torch.float32)
    Y = torch.tensor(y, dtype=torch.float32)
    W = torch.tensor(w / w.mean(), dtype=torch.float32)
    net = torch.nn.Sequential(torch.nn.Linear(x.shape[1], 128), torch.nn.GELU(), torch.nn.Dropout(0.3), torch.nn.Linear(128, 1))
    optimizer = torch.optim.AdamW(net.parameters(), 1e-3, weight_decay=1e-2)
    for _ in range(15):
        net.train()
        for rows in torch.randperm(len(X)).split(512):
            out = net(X[rows] + 0.1 * torch.randn_like(X[rows]))[:, 0]
            loss = (torch.nn.functional.binary_cross_entropy_with_logits(out, Y[rows], reduction="none") * W[rows]).mean()
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
    net.eval()
    layers = [m for m in net if isinstance(m, torch.nn.Linear)]
    return {"layers": [{"weights": l.weight.detach().double().numpy().tolist(), "bias": l.bias.detach().double().numpy().tolist()}
                       for l in layers], "threshold": RAISE_THRESHOLD, "lockout": RAISE_LOCKOUT}


def raise_probability(network, x):
    h = (x - np.array(network["inputMean"])) / np.array(network["inputStd"])
    layers = network["raise"]["layers"]
    for k, layer in enumerate(layers):
        h = h @ np.array(layer["weights"]).T + np.array(layer["bias"])
        if k < len(layers) - 1:
            h = gelu(h)
    return 1 / (1 + np.exp(-h[:, 0]))


def clicks(probability, threshold=RAISE_THRESHOLD, lockout=RAISE_LOCKOUT):
    """Frames where a click fires, as FingerCursor.swift fires them: over the threshold, no click
    in the lockout before, and the detector under 0.5 since the last click."""
    out, last, armed = [], -lockout - 1, True
    for k, p in enumerate(probability):
        if p < 0.5:
            armed = True
        if armed and p > threshold and k - last > lockout:
            out.append(k)
            last, armed = k, False
    return np.array(out, int)


def gelu(x):
    from scipy.special import erf
    return 0.5 * x * (1 + erf(x / np.sqrt(2)))


def run_network(network, x):
    h = (x - np.array(network["inputMean"])) / np.array(network["inputStd"])
    layers = network["layers"]
    for k, layer in enumerate(layers):
        h = h @ np.array(layer["weights"]).T + np.array(layer["bias"])
        if k < len(layers) - 1:
            h = gelu(h)
    return 1 / (1 + np.exp(-h[:, 0])), h[:, 1:] * VELOCITY_SCALE


def score(network, x, contact, velocity):
    probability, guess = run_network(network, x)
    out = {"touch": roc_auc_score(contact, probability) if 0 < contact.mean() < 1 else np.nan}
    for axis, name in ((0, "left-right"), (1, "up-down")):
        fast = np.isfinite(velocity[:, axis]) & (np.abs(velocity[:, axis]) > 20)
        out[name] = (np.sign(guess[fast, axis]) == np.sign(velocity[fast, axis])).mean()
    # Whole strokes: an unbroken slide of 200 ms or more. Along each axis it moved 5 mm or
    # more, does the decoded travel point the same way as the real one?
    sliding = np.isfinite(velocity[:, 0])
    edges = np.flatnonzero(np.diff(np.concatenate([[0], sliding.astype(int), [0]])))
    right = {0: [], 1: []}
    for start, end in zip(edges[::2], edges[1::2]):
        if end - start < 10:
            continue
        real, decoded = velocity[start:end].sum(0) * HOP / RATE, guess[start:end].sum(0)
        for axis in (0, 1):
            if abs(real[axis]) >= 5:
                right[axis].append(np.sign(decoded[axis]) == np.sign(real[axis]))
    out["strokes"] = (np.mean(right[0]) if right[0] else np.nan, np.mean(right[1]) if right[1] else np.nan, len(right[0]) + len(right[1]))
    return out


def rows(r, features, mask=None):
    keep = r["keep"] if mask is None else r["keep"] & mask
    return features[keep], r["contact"][keep], r["velocity"][keep]


def pack(parts, weight):
    x = np.vstack([p[0] for p in parts])
    return x, np.concatenate([p[1] for p in parts]), np.vstack([p[2] for p in parts]), \
        np.concatenate([np.full(len(p[0]), w) for p, w in zip(parts, weight)])


def export(network, reference, recordings, path):
    model = {
        "rate": RATE, "hop": HOP, "window": WINDOW, "lags": list(LAGS), "shrink": SHRINK,
        "bands": [{"low": low, "high": high, "sos": sos_for(low, high).tolist()} for low, high in BANDS],
        "reference": reference.tolist(), "velocityScale": VELOCITY_SCALE, **network,
        "gyro": {"lags": GYRO_LAGS, "scale": GYRO_SCALE},
        "trainedOn": [r["name"] for r in recordings],
    }
    path.write_text(json.dumps(model))


def write_fixture(path):
    """Synthetic sEMG and gyro with band and arrival times, a random network, and this recipe's
    outputs, for TrackpadDecoderTests. The test feeds the events in arrival order."""
    rng = np.random.default_rng(7)
    batches = 400
    n = 16 * batches
    mixing = rng.normal(size=(8, 8)) * 0.3 + np.eye(8)
    envelope = 1 + 0.8 * np.sin(np.arange(n) / 700)[:, None] * np.linspace(-1, 1, 8)[None]
    samples = np.clip(2048 + 60 * (rng.normal(size=(n, 8)) @ mixing) * envelope, 0, 4095).round()
    emg_band = 1000 + np.arange(batches) * 16 / RATE
    emg_arrival = np.maximum.accumulate(emg_band + 5 + rng.uniform(0.004, 0.03, batches))   # a stream stays in order
    gyro_band = 1000 - 0.05 + np.arange(int((n / RATE + 0.1) * 128)) / 128
    gyro_arrival = gyro_band + 5 + rng.uniform(0.004, 0.03, len(gyro_band))
    gyro_values = 400 + 150 * np.sin(np.arange(len(gyro_band))[:, None] / np.array([9.0, 23.0, 41.0])) + rng.normal(size=(len(gyro_band), 3)) * 20
    reference = log_covariances(covariances(samples)).mean(0) + 0.2
    n_frames = n // HOP
    features = np.hstack([lagged(tangent(covariances(samples), log_covariances(covariances(samples)), reference)),
                          gyro_features(emg_band, emg_arrival, gyro_band, gyro_arrival, gyro_values, n_frames)])[max(LAGS):]
    width = features.shape[1]
    network = {"inputMean": rng.normal(size=width).tolist(), "inputStd": (1 + rng.random(width)).tolist(),
               "layers": [{"weights": (rng.normal(size=(o, i)) / np.sqrt(i)).tolist(), "bias": rng.normal(size=o).tolist()}
                          for i, o in ((width, 16), (16, 8), (8, 3))]}
    network["raise"] = {"layers": [{"weights": (rng.normal(size=(o, i)) / np.sqrt(i)).tolist(), "bias": rng.normal(size=o).tolist()}
                                   for i, o in ((width, 6), (6, 1))], "threshold": RAISE_THRESHOLD, "lockout": RAISE_LOCKOUT}
    contact, velocity = run_network(network, features)
    raised = raise_probability(network, features)
    model = {"rate": RATE, "hop": HOP, "window": WINDOW, "lags": list(LAGS), "shrink": SHRINK,
             "bands": [{"low": low, "high": high, "sos": sos_for(low, high).tolist()} for low, high in BANDS],
             "reference": reference.tolist(), "velocityScale": VELOCITY_SCALE, **network,
             "gyro": {"lags": GYRO_LAGS, "scale": GYRO_SCALE}}
    path.write_text(json.dumps({
        "model": model, "samples": samples.astype(int).reshape(-1).tolist(),
        "emgBand": emg_band.tolist(), "emgArrival": emg_arrival.tolist(),
        "gyroBand": gyro_band.tolist(), "gyroArrival": gyro_arrival.tolist(), "gyroValues": gyro_values.tolist(),
        "contact": contact.tolist(), "velocity": velocity.tolist(), "raise": raised.tolist()}))
    print(f"wrote {path}")


def in_app(network, stream, minutes):
    """The network after learning inside Kinesis from the first `minutes` of a stream of
    (features, contact, velocity) in time order, with the frame caps LiveTrackpad.swift keeps."""
    x, contact, velocity = stream
    n = int(minutes * 60 * RATE / HOP)
    x, contact, velocity = x[:n], contact[:n], velocity[:n]
    sliding = np.flatnonzero(np.isfinite(velocity[:, 0]))[-12_000:]
    other = np.flatnonzero(~np.isfinite(velocity[:, 0]))[-12_000:]
    keep = np.concatenate([sliding, other])
    scaled = (x[keep] - np.array(network["inputMean"])) / np.array(network["inputStd"])
    return fine_tune(network, scaled, contact[keep], velocity[keep], **FINE_TUNE)


def load_each(prepare, folders):
    """Prepares each recording. A damaged one is skipped with a note, never fatal."""
    out = []
    for folder in folders:
        try:
            out.append(prepare(folder))
        except (OSError, ValueError, KeyError, IndexError) as error:
            print(f"skipped {folder.parent.name}/{folder.name}: {error}")
    return out


def main():
    if "--fixture" in sys.argv:
        write_fixture(here.parent / "Tests/KinesisTests/Fixtures/trackpad-decoder.json")
        write_fine_tune_fixture(here.parent / "Tests/KinesisTests/Fixtures/trackpad-fine-tune.json")
    # Passive recordings only: the early cued runs have no gyro, and scored no better.
    recordings = load_each(prepare_passive, passive_segments())
    if not recordings:
        sys.exit("no passive recordings to train on yet")
    day_of = lambda r: r["name"].split()[1].split("/")[0]
    minutes = {}
    for r in recordings:
        minutes[day_of(r)] = minutes.get(day_of(r), 0) + len(r["frame"]) * HOP / RATE / 60
    days = sorted(minutes)
    desk = load_each(prepare_desk, desk_sessions())
    raises = load_each(prepare_raises, raise_sessions())
    print(f"{len(recordings)} recordings over {len(days)} day(s), {len(desk)} desk session(s) for touch, "
          f"and {len(raises)} raise recording(s) for clicks.")

    # Honest scores on the newest day with 20 minutes or more, by a model from the days before it.
    tested = [d for d in days if minutes[d] >= 20]
    if len(tested) >= 2:
        test_day = tested[-1]
        older = [r for r in recordings if day_of(r) < test_day] + [d for d in desk if day_of(d) < test_day]
        newest = [r for r in recordings if day_of(r) == test_day]
        reference = reference_for(older)
        features = {id(r): featurize(r, reference) for r in recordings + desk}
        x, contact, velocity, weight = pack([rows(r, features[id(r)]) for r in older], [1] * len(older))
        network = train_network(x, contact, velocity, weight)
        head, tail = [], []
        for r in newest:
            n = len(r["frame"])
            head.append(rows(r, features[id(r)], np.arange(n) < 0.7 * n))
            tail.append(rows(r, features[id(r)], np.arange(n) > 0.7 * n + 50))
        stream = pack(head, [1] * len(head))[:3]
        test = pack(tail, [1] * len(tail))[:3]
        print(f"\non {test_day}'s last 30 %, with a model from the days before. touch 0.5 and direction 50 % are chance.")
        print("direction frame by frame, 20 ms each, then over whole strokes of 200 ms or more:")
        for label, tuned in (("fresh", network), ("after 2 min of use", in_app(network, stream, 2)),
                             ("after 10 min of use", in_app(network, stream, 10))):
            s = score(tuned, *test)
            print(f"  {label:20s} touch {s['touch']:.2f}, left-right {s['left-right']:.0%}, up-down {s['up-down']:.0%}"
                  f"   whole strokes: left-right {s['strokes'][0]:.0%}, up-down {s['strokes'][1]:.0%}", flush=True)

        if raises:
            # Clicks: raises caught on trials held out, four ways, and false clicks over the whole
            # test day's normal use, by a detector that never saw that day.
            raise_features = [featurize(r, reference) for r in raises]
            negatives = [raise_negatives(r, features[id(r)]) for r in older if not r["name"].startswith("desk")]
            neg_x, neg_w = np.vstack([n[0] for n in negatives]), np.concatenate([n[1] for n in negatives])
            caught = rests = raised = rested = 0
            for fold in range(4):
                pos, extra = [], []
                for r, f in zip(raises, raise_features):
                    use = (r["trial"] >= 0) & ((r["trial"] // 8) % 4 != fold)
                    pos.append(f[use & (r["raise"] == 1)])
                    extra.append(f[use & (r["raise"] == 0)])
                detector = {**network, "raise": train_raise(network, np.vstack(pos), np.vstack([neg_x] + extra),
                                                            np.r_[neg_w, np.ones(sum(len(e) for e in extra))])}
                for r, f in zip(raises, raise_features):
                    p = raise_probability(detector, f)
                    for n in np.flatnonzero((np.arange(len(r["cues"])) // 8) % 4 == fold):
                        window = p[r["trial"] == n][-38:]
                        if r["cues"]["kind"][n] > 0:
                            raised += 1
                            caught += window.max() > RAISE_THRESHOLD
                        else:
                            rested += 1
                            rests += window.max() > RAISE_THRESHOLD
            pos = np.vstack([f[r["raise"] == 1] for r, f in zip(raises, raise_features)])
            extra = np.vstack([f[r["raise"] == 0] for r, f in zip(raises, raise_features)])
            detector = {**network, "raise": train_raise(network, pos, np.vstack([neg_x, extra]), np.r_[neg_w, np.ones(len(extra))])}
            false = sum(len(clicks(raise_probability(detector, features[id(r)]))) for r in newest)
            print(f"  clicks: raises caught {caught} of {raised} on unseen trials, rests firing {rests} of {rested}, "
                  f"{false / minutes[test_day]:.1f} false clicks a minute over {test_day}'s normal use", flush=True)

    # The export: every recording, alike. Each wearing's own learning happens inside Kinesis.
    recordings = recordings + desk
    reference = reference_for(recordings)
    features = {id(r): featurize(r, reference) for r in recordings}
    x, contact, velocity, weight = pack([rows(r, features[id(r)]) for r in recordings], [1] * len(recordings))
    network = train_network(x, contact, velocity, weight)
    if raises:
        raise_features = [featurize(r, reference) for r in raises]
        negatives = [raise_negatives(r, features[id(r)]) for r in recordings if not r["name"].startswith("desk")]
        pos = np.vstack([f[r["raise"] == 1] for r, f in zip(raises, raise_features)])
        extra = np.vstack([f[r["raise"] == 0] for r, f in zip(raises, raise_features)])
        network["raise"] = train_raise(network, pos, np.vstack([n[0] for n in negatives] + [extra]),
                                       np.r_[np.concatenate([n[1] for n in negatives]), np.ones(len(extra))])
    arguments = sys.argv[1:]
    out = Path(arguments[arguments.index("--out") + 1]).expanduser() if "--out" in arguments else check.LAB / "decoder.json"
    export(network, reference, recordings + raises, out)
    print(f"\nexported {out}")


if __name__ == "__main__":
    main()
