#!/usr/bin/env python3
"""KRunner's folds and unfolds from frametimes.sh's logs: for each, the steps that came more than 1.5 frames
after the one before (KRunner dropped frames there) and the vblanks KWin skipped meanwhile, with its render times.
A run of size changes no more than 100 ms apart counts as one fold or unfold. The step to the last pixel can
come late on its own: the easing's tail moves less than a pixel a frame there, so that one isn't a drop.

    frametimes.py OUTDIR
"""

import glob
import json
import sys


def main(out):
    offset = float(open(f"{out}/clock-offset").read())  # wall clock minus monotonic, ms
    sizes = []
    for line in open(f"{out}/krunner.log"):
        _, stamp, _, geometry = line.split(" ", 3)
        sizes.append((int(stamp) - offset, json.loads(geometry)["height"]))
    frames = []  # (page flip, render time) ms
    period = 1000 / 60
    for path in glob.glob(f"{out}/kwin perf statistics *.csv"):
        with open(path) as f:
            next(f)
            for line in f:
                v = line.strip().split(",")
                if len(v) < 9:  # cut off as KWin quit
                    continue
                frames.append((int(v[1]) / 1e6, (int(v[3]) - int(v[2])) / 1e6))
                period = int(v[5]) / 1e6
    frames.sort()
    runs, run = [], sizes[:1]
    for s in sizes[1:]:
        if s[0] - run[-1][0] > 100:
            runs.append(run)
            run = [s]
        else:
            run.append(s)
    runs.append(run)
    print(f"refresh {period:.2f} ms")
    for run in runs:
        if len(run) < 4:
            continue
        kind = "unfold" if run[-1][1] > run[0][1] else "fold"
        gaps = [(b[0] - a[0], a[1], b[1]) for a, b in zip(run, run[1:])]
        late = [g for g in gaps[:-1] if g[0] > 1.5 * period]  # the last step: the tail's pixel
        during = [f for f in frames if run[0][0] - 5 <= f[0] <= run[-1][0] + 5]
        flips = [f[0] for f in during]
        skipped = sum(round((b - a) / period) - 1 for a, b in zip(flips, flips[1:]) if b - a > 1.5 * period)
        render = sorted(f[1] for f in during) or [0]
        drops = ", ".join(f"{h0}->{h1} px after {g:.0f} ms" for g, h0, h1 in late) or "none"
        print(f"{kind:6s} {run[0][1]:4d}->{run[-1][1]:4d} px in {run[-1][0] - run[0][0]:3.0f} ms: dropped at {drops}; "
              f"KWin skipped {skipped} vblanks, rendered in {render[len(render) // 2]:.1f} ms (at most {render[-1]:.1f})")


if __name__ == "__main__":
    main(sys.argv[1])
