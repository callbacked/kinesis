#!/usr/bin/env python3
"""Tests simulated band rotation for the live decoder, across wearings.

    scripts/trackpad-rotation.py

A re-worn band sits rotated a little. Training can pretend that happened by shifting
the channels along the band. On this band the 8 channels run in an arc, not a ring:
neighbors correlate 0.82 to 0.88, while channel 7 and channel 0 correlate only 0.31.
So a shift moves each channel along the arc and repeats the end channel, with no
wrap. A half shift mixes neighbors, like an electrode between two.

Each recipe trains on all wearings but one and is scored on the one left out.
"""
import importlib.util
from pathlib import Path

import numpy as np
from sklearn.linear_model import LogisticRegression, Ridge
from sklearn.metrics import roc_auc_score

here = Path(__file__).parent
spec = importlib.util.spec_from_file_location("train", here / "trackpad-train.py")
train = importlib.util.module_from_spec(spec)
spec.loader.exec_module(train)


def shifted(values, amount):
    """Channels moved `amount` places along the arc, a fraction mixing two neighbors."""
    whole = int(np.floor(amount))
    part = amount - whole
    index = np.arange(8)

    def move(k):
        return values[:, np.clip(index + k, 0, 7)]

    return move(whole) if part == 0 else (1 - part) * move(whole) + part * move(whole + 1)


def load(folder):
    emg_times, values = train.check.load_emg(folder / "emg.jsonl")
    base = train.prepare(folder)
    return base, values


def features(frame):
    z = (frame - frame.mean(0)) / (frame.std(0) + 1e-6)
    return train.stack(z)


def fit(recordings, shifts):
    xs, contacts, velocities = [], [], []
    for base, values in recordings:
        keep = base["keep"]
        for amount in shifts:
            frame = base["frame"] if amount == 0 else train.frames(shifted(values, amount))[:len(base["frame"])]
            xs.append(features(frame)[keep])
            contacts.append(base["contact"][keep])
            velocities.append(base["velocity"][keep])
    x, contact, velocity = np.vstack(xs), np.concatenate(contacts), np.vstack(velocities)
    moving = np.isfinite(velocity[:, 0])
    return (LogisticRegression(max_iter=4000, C=0.1).fit(x, contact),
            Ridge(alpha=100).fit(x[moving], velocity[moving]))


def score(model, held, averaged):
    classifier, regressor = model
    base, values = held
    keep = base["keep"]
    shifts = (-1, 0, 1) if averaged else (0,)
    probabilities, guesses = [], []
    for amount in shifts:
        frame = base["frame"] if amount == 0 else train.frames(shifted(values, amount))[:len(base["frame"])]
        x = features(frame)[keep]
        probabilities.append(classifier.predict_proba(x)[:, 1])
        guesses.append(regressor.predict(x))
    probability, guess = np.mean(probabilities, 0), np.mean(guesses, 0)
    contact, velocity = base["contact"][keep], base["velocity"][keep]
    out = [roc_auc_score(contact, probability)]
    for axis in (0, 1):
        fast = np.isfinite(velocity[:, axis]) & (np.abs(velocity[:, axis]) > 20)
        out.append((np.sign(guess[fast, axis]) == np.sign(velocity[fast, axis])).mean())
    return out


def main():
    runs = sorted(p for p in train.check.LAB.glob("*-trackpad") if train.check.long_enough(p))
    recordings = [load(r) for r in runs]
    recipes = [
        ("as now", (0,), False),
        ("shift ±1", (-1, 0, 1), False),
        ("shift ±½ and ±1", (-1, -0.5, 0, 0.5, 1), False),
        ("shift ±½ and ±1, averaged", (-1, -0.5, 0, 0.5, 1), True),
    ]
    print(f"{len(recordings)} wearings, each scored by a model trained on the others.")
    print("touch: 0.5 is chance. direction: 50 % is chance, on slides over 20 mm/s.\n")
    for name, shifts, averaged in recipes:
        scores = [score(fit([r for r in recordings if r is not held], shifts), held, averaged) for held in recordings]
        s = np.array(scores)
        print(f"  {name:28s} touch {' '.join(f'{v:.2f}' for v in s[:, 0])} (avg {s[:, 0].mean():.2f})   "
              f"left-right avg {s[:, 1].mean():.0%}   up-down avg {s[:, 2].mean():.0%}")


if __name__ == "__main__":
    main()
