#!/usr/bin/env python3
"""Trains stronger decoders on trackpad recordings, tested across wearings.

    scripts/trackpad-model.py              every trackpad recording
    scripts/trackpad-model.py --last 3     the three newest

Each recording is one wearing of the band. Every model trains on all wearings but one
and is scored on the one left out, then the left-out wearing rotates. That is the
test that matters: a decoder has to work the next time the band goes on.

Two models: ridge regression on band power per channel, and a small convolutional
network on the filtered sEMG itself. Needs numpy, scipy, scikit-learn, and torch.
"""
import importlib.util
import sys
from pathlib import Path

import numpy as np
import torch
from scipy.signal import butter, sosfiltfilt
from sklearn.linear_model import LogisticRegression, Ridge
from sklearn.metrics import roc_auc_score

here = Path(__file__).parent
spec = importlib.util.spec_from_file_location("check", here / "trackpad-check.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

RATE = 2048
HOP = 0.02
BANDS = [(20, 60), (60, 120), (120, 250), (250, 450)]
CONTEXT = 10          # 10 windows of 20 ms: the last 200 ms
RAW_WINDOW = 0.2      # the network reads the last 200 ms at 1024 Hz


def uniform(times, values):
    """Resamples onto an even 2048 Hz grid. Radio gaps become flagged zeros."""
    grid = np.arange(times[0], times[-1], 1 / RATE)
    index = np.clip(np.searchsorted(times, grid), 1, len(times) - 1)
    near = np.where(np.abs(times[index - 1] - grid) < np.abs(times[index] - grid), index - 1, index)
    missing = np.abs(times[near] - grid) > 2 / RATE
    out = values[near].copy()
    out[missing] = 0
    return grid, out, missing


def prepare(folder):
    grid, _, contact, velocity, emg_times, values = check.recording(folder)
    times, even, missing = uniform(emg_times, values)
    centered = even - np.where(missing[:, None], 0, even).sum(0) / max(1, (~missing).sum())
    centered[missing] = 0
    filtered = sosfiltfilt(butter(4, [20, 450], btype="band", fs=RATE, output="sos"), centered, axis=0)
    filtered[missing] = 0
    # Band power per channel, per 20 ms, then the last 200 ms of it.
    powers = []
    for low, high in BANDS:
        band = sosfiltfilt(butter(4, [low, high], btype="band", fs=RATE, output="sos"), filtered, axis=0)
        cumulative = np.concatenate([np.zeros((1, 8)), np.cumsum(band ** 2, axis=0)])
        ends = np.clip(np.searchsorted(times, grid), 0, len(times))
        starts = np.clip(np.searchsorted(times, grid - HOP), 0, len(times))
        powers.append(np.log((cumulative[ends] - cumulative[starts]) / np.maximum(1, ends - starts)[:, None] + 1e-2))
    frame = np.hstack(powers)
    frame = (frame - frame.mean(0)) / (frame.std(0) + 1e-6)
    stacked = np.hstack([np.roll(frame, k, axis=0) for k in range(CONTEXT)])
    # Raw windows for the network, at 1024 Hz, scaled by this wearing's own spread.
    scale = filtered[~missing].std(0) + 1e-6
    half = (filtered / scale)[::2]
    half_times = times[::2]
    length = int(RAW_WINDOW * RATE / 2)
    ends = np.searchsorted(half_times, grid)
    valid = (ends >= length) & (ends <= len(half_times))
    gap = np.convolve(missing[::2].astype(float), np.ones(length), mode="full")[:len(half_times)]
    valid &= np.array([gap[e - 1] < 0.2 * length if e >= length else False for e in ends])
    return {"name": folder.name, "features": stacked, "contact": contact, "velocity": velocity,
            "raw": half.astype(np.float32), "ends": ends, "valid": valid, "length": length}


def shifted(labels, lag):
    """Labels `lag` steps later: muscle activity comes before the movement it causes."""
    if lag == 0:
        return labels
    out = np.empty_like(labels)
    out[:-lag] = labels[lag:]
    out[-lag:] = labels[-1]
    return out


def score(contact, contact_guess, velocity, velocity_guess):
    result = {}
    if contact.any() and not contact.all():
        result["contact"] = roc_auc_score(contact, contact_guess)
    for axis, name in ((0, "left-right"), (1, "up-down")):
        ok = np.isfinite(velocity[:, axis]) & np.isfinite(velocity_guess[:, axis])
        fast = ok & (np.abs(velocity[:, axis]) > 20)
        if fast.sum() > 30:
            result[name] = (np.sign(velocity_guess[fast, axis]) == np.sign(velocity[fast, axis])).mean()
            result[name + " corr"] = np.corrcoef(velocity[ok, axis], velocity_guess[ok, axis])[0, 1]
    return result


def ridge(train, test, lag):
    x = np.vstack([r["features"][r["valid"]] for r in train])
    contact = np.concatenate([shifted(r["contact"], lag)[r["valid"]] for r in train])
    velocity = np.vstack([shifted(r["velocity"], lag)[r["valid"]] for r in train])
    moving = np.isfinite(velocity[:, 0])
    classifier = LogisticRegression(max_iter=3000, C=0.1).fit(x, contact)
    regressor = Ridge(alpha=100).fit(x[moving], velocity[moving])
    tx = test["features"][test["valid"]]
    return score(shifted(test["contact"], lag)[test["valid"]], classifier.predict_proba(tx)[:, 1],
                 shifted(test["velocity"], lag)[test["valid"]], regressor.predict(tx))


class Net(torch.nn.Module):
    """Convolutions over 200 ms of 8-channel sEMG: touch, and velocity across and along."""

    def __init__(self):
        super().__init__()
        layers, channels = [], 8
        for width in (32, 32, 64, 64):
            layers += [torch.nn.Conv1d(channels, width, 7, padding=3), torch.nn.BatchNorm1d(width),
                       torch.nn.GELU(), torch.nn.MaxPool1d(2)]
            channels = width
        self.body = torch.nn.Sequential(*layers, torch.nn.AdaptiveAvgPool1d(1), torch.nn.Flatten(), torch.nn.Dropout(0.3))
        self.head = torch.nn.Linear(channels, 3)

    def forward(self, x):
        return self.head(self.body(x))


def windows(r, lag, indices):
    raw = torch.from_numpy(r["raw"])
    starts = r["ends"][indices] - r["length"]
    x = torch.stack([raw[s:s + r["length"]].T for s in starts])
    contact = shifted(r["contact"], lag)[indices].astype(np.float32)
    velocity = shifted(r["velocity"], lag)[indices].astype(np.float32) / 100  # in 100 mm/s
    return x, torch.from_numpy(contact), torch.from_numpy(velocity)


def network(train, test, lag, device, epochs=12, seed=0):
    torch.manual_seed(seed)
    np.random.seed(seed)
    model = Net().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-2)
    pools = [(r, np.flatnonzero(r["valid"])) for r in train]
    for _ in range(epochs):
        model.train()
        order = [(r, i) for r, idx in pools for i in np.random.permutation(idx)]
        np.random.shuffle(order)
        for start in range(0, len(order), 256):
            chunk = order[start:start + 256]
            parts = [windows(r, lag, np.array([i for rr, i in chunk if rr is r])) for r in train
                     if any(rr is r for rr, _ in chunk)]
            x = torch.cat([p[0] for p in parts]).to(device)
            contact = torch.cat([p[1] for p in parts]).to(device)
            velocity = torch.cat([p[2] for p in parts]).to(device)
            # A little gain noise per window, since the next wearing sits differently.
            x = x * (1 + 0.15 * torch.randn(x.shape[0], 8, 1, device=device))
            out = model(x)
            moving = torch.isfinite(velocity[:, 0])
            loss = torch.nn.functional.binary_cross_entropy_with_logits(out[:, 0], contact)
            if moving.any():
                loss = loss + torch.nn.functional.smooth_l1_loss(out[moving, 1:], velocity[moving])
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
    model.eval()
    indices = np.flatnonzero(test["valid"])
    guesses = []
    with torch.no_grad():
        for start in range(0, len(indices), 1024):
            x, _, _ = windows(test, lag, indices[start:start + 1024])
            guesses.append(model(x.to(device)).cpu().numpy())
    guess = np.vstack(guesses)
    return score(shifted(test["contact"], lag)[indices], guess[:, 0],
                 shifted(test["velocity"], lag)[indices], guess[:, 1:] * 100)


def report(label, results):
    keys = ["contact", "left-right", "up-down", "left-right corr", "up-down corr"]
    cells = []
    for key in keys:
        values = [r[key] for r in results if key in r]
        if values:
            fmt = "{:.2f}" if key == "contact" or key.endswith("corr") else "{:.0%}"
            cells.append(f"{key} " + "/".join(fmt.format(v) for v in values))
    print(f"  {label:22s} " + "   ".join(cells))


def main():
    arguments = sys.argv[1:]
    runs = sorted(p for p in check.LAB.glob("*-trackpad") if check.long_enough(p))
    if arguments[:1] == ["--last"]:
        runs = runs[-int(arguments[1]):]
    if len(runs) < 2:
        sys.exit("needs two trackpad recordings or more")
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    recordings = [prepare(r) for r in runs]
    print(f"{len(recordings)} wearings. each score is one left-out wearing, in order.")
    print("contact: 0.5 is chance. direction: 50 % is chance, on moves over 20 mm/s.\n")
    for lag_ms in (0, 40, 80):
        lag = lag_ms // 20
        print(f"labels {lag_ms} ms after the sEMG:")
        folds = [([r for r in recordings if r is not held], held) for held in recordings]
        report("band power + ridge", [ridge(train, held, lag) for train, held in folds])
        report("conv network", [network(train, held, lag, device) for train, held in folds])
        print()


if __name__ == "__main__":
    main()
