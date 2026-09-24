#!/usr/bin/env python3
"""Compare recorded sensor orientation against integrated gyro (requires NumPy 2)."""
import argparse
import json
import numpy as np


def multiply(a, b):
    vector = a[3] * b[:3] + b[3] * a[:3] + np.cross(a[:3], b[:3])
    scalar = a[3] * b[3] - a[:3] @ b[:3]
    return np.r_[vector, scalar]


def inverse(q):
    return q * np.array([-1, -1, -1, 1])


def compare(gyro, orientation, order, frame):
    integrated, observed = [], []
    for start, end in zip(orientation[:-1], orientation[1:]):
        if not 0.02 < end[0] - start[0] < 0.3:
            continue
        lo = max(0, np.searchsorted(gyro[:, 0], start[0]) - 1)
        hi = min(len(gyro), np.searchsorted(gyro[:, 0], end[0]) + 1)
        segment = gyro[lo:hi]
        if (len(segment) < 3 or np.diff(segment[:, 0]).max() > 0.05
                or segment[0, 0] > start[0] or segment[-1, 0] < end[0]):
            continue
        inside = segment[(segment[:, 0] > start[0]) & (segment[:, 0] < end[0]), 0]
        times = np.r_[start[0], inside, end[0]]
        samples = np.array([np.interp(times, gyro[:, 0], gyro[:, axis]) for axis in [1, 2, 3]]).T
        rotation = np.trapezoid(samples, times, axis=0) * 0.07 * np.pi / 180
        if np.linalg.norm(rotation) < 0.02:
            continue
        a, b = start[1:], end[1:]
        if order == 'wxyz':
            a, b = a[[1, 2, 3, 0]], b[[1, 2, 3, 0]]
        a, b = a / np.linalg.norm(a), b / np.linalg.norm(b)
        delta = multiply(inverse(a), b) if frame == 'body' else multiply(b, inverse(a))
        if delta[3] < 0:
            delta = -delta
        magnitude = np.linalg.norm(delta[:3])
        vector = delta[:3] * 2 * np.arctan2(magnitude, delta[3]) / max(magnitude, 1e-10)
        integrated.append(rotation)
        observed.append(vector)
    if not integrated:
        raise ValueError('No continuous moving intervals found')
    integrated, observed = np.array(integrated), np.array(observed)
    matrix = np.linalg.lstsq(integrated, observed, rcond=None)[0]
    norm = np.linalg.norm(observed)
    return {
        'order': order, 'frame': frame, 'intervals': len(integrated),
        'unfitted_relative_error': float(np.linalg.norm(integrated - observed) / norm),
        'fitted_relative_error': float(np.linalg.norm(integrated @ matrix - observed) / norm),
        'fitted_matrix': matrix.round(4).tolist(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', help='PoC JSONL capture; only decoded sensor rows are retained')
    args = parser.parse_args()
    rows = {'gyro_sample': [], 'orientation_sample': []}
    with open(args.capture) as capture:
        for line in capture:
            row = json.loads(line)
            if row.get('event') in rows:
                rows[row['event']].append([row['timestamp_us'] * 1e-6, *row['values']])
    gyro, orientation = np.array(rows['gyro_sample']), np.array(rows['orientation_sample'])
    if len(gyro) < 3 or len(orientation) < 2:
        parser.error('The capture needs both gyro and orientation samples')
    for order in ['xyzw', 'wxyz']:
        for frame in ['body', 'world']:
            print(json.dumps(compare(gyro, orientation, order, frame)))


if __name__ == '__main__':
    main()
