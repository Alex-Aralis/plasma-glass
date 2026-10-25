#!/usr/bin/env python3
"""A numpy model of the Liquid Glass effect's liquid, for testing changes to it off screen.

It runs kwin-effect/shaders/fluid.frag's ripples layer cell for cell as the GPU does (linear shallow water
on a staggered grid, the shore and floor shaped by the same patterns, the sponge along the rim, the click's
press and its finger) with runLiquid's step sizes and the user's [Ripple] tuning from plasma-glassrc. Not
modelled: the busy pushes and breeze (KRunner's), the swell layer and the window's momentum, the surface
and the glass drawn over it.

  liquid.sh drag [SPEED...]     a press dragged straight across the glass at each speed (px/s): where its
                                dent is against the press, how deep, how rough the trench behind it
  liquid.sh click               a plain click: the rings it sends off as it's pressed and as it's let go
  liquid.sh check               drag and click against what they should do (exit status 1 if not)
  liquid.sh compare DIR         the model run on a KWIN_LIQUID_GLASS_CLICK_LOG=DIR log (tools/liquid/record.sh),
                                held against the real liquid read back each frame

See tools/liquid/README.md. Keep this in step with fluid.frag and runLiquid: `compare` shows when they drift.
"""
import argparse
import configparser
import math
import os
import sys

import numpy as np

# liquidglass.cpp's constants
RIPPLES_CELL = 3.0
LIQUID_RIM = 32.0
LIQUID_LEVEL = 1.0 / 3.0
CLICK_FINGER = 0.004
# where the finger puts the liquid it pushes down: a ring this many press widths out, this many wide
FINGER_RING = 2.0
FINGER_RING_WIDTH = 0.6

# [Ripple] keys the liquid reads: (default, low, high), as LiquidGlassEffect::reconfigure clamps them
TUNING = {
    "speed": (120, 20, 1000),
    "damping": (36, 0.2, 600),
    "reflection": (0.3, 0, 1),
    "shore": (8, 0, 60),
    "shoreScale": (120, 10, 1000),
    "floor": (0.35, 0, 0.8),
    "floorScale": (220, 20, 2000),
    "click": (1, 0, 5),
    "clickWidth": (24, 2, 200),
}


def read_tuning(path):
    tuning = {key: float(spec[0]) for key, spec in TUNING.items()}
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    if path and os.path.exists(path):
        parser.read(path)
    if parser.has_section("Ripple"):
        for key, (_, low, high) in TUNING.items():
            if parser.has_option("Ripple", key):
                try:
                    tuning[key] = min(max(float(parser.get("Ripple", key)), low), high)
                except ValueError:
                    pass
    return tuning


def pattern(x, y, size, seed):
    """fluid.frag's pattern(): three plane waves at odd angles, -1..1 or so, in bends about size px long"""
    qx = x / size * 2 * math.pi
    qy = y / size * 2 * math.pi
    return (0.55 * np.sin(qx * 0.83 + qy * 0.56 + seed)
            + 0.35 * np.sin(-qx * 0.48 + qy * 1.31 + 2.3 * seed + 1.1)
            + 0.25 * np.sin(qx * 1.62 - qy * 0.37 + 3.7 * seed + 2.9))


def rounded_box(x, y, width, height, corners):
    """KWin's sdfRoundedBox for the glass, corners top left, top right, bottom left, bottom right"""
    px, py = x - width / 2, y - height / 2
    tl, tr, bl, br = corners
    r = np.where(px > 0, np.where(py < 0, tr, br), np.where(py < 0, tl, bl))
    qx = np.abs(px) - width / 2 + r
    qy = np.abs(py) - height / 2 + r
    return np.minimum(np.maximum(qx, qy), 0) + np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) - r


def smooth_step(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3 - 2 * t)


class Liquid:
    """The ripples in one Liquid Glass window: a height per cell and the velocities on its right and bottom
    faces, cell (i, j) at ((i - 0.5) cell, (j - 0.5) cell) in the glass (y down), as in fluid.frag"""

    def __init__(self, tuning, width, height, corners=(16, 16, 16, 16), seed=0.0):
        self.tuning = tuning
        self.width, self.height = width, height
        cell = RIPPLES_CELL
        self.nx = int(math.ceil(width / cell)) + 3
        self.ny = int(math.ceil(height / cell)) + 3
        xs = (np.arange(self.nx) - 0.5) * cell
        ys = (np.arange(self.ny) - 0.5) * cell
        self.X, self.Y = np.meshgrid(xs, ys)
        c = tuning["speed"]
        self.c2 = c * c
        across = min(width, height)
        shore_in = min(tuning["shore"], 0.12 * across)
        self.rim_width = min(max(0.5 * across - 2, 4.0), LIQUID_RIM)
        self.shore = rounded_box(self.X, self.Y, width, height, corners) + shore_in + shore_in * pattern(self.X, self.Y, tuning["shoreScale"], seed)
        self.depth = 1 + tuning["floor"] * pattern(self.X, self.Y, tuning["floorScale"], seed * 1.37 + 5) / 1.15
        self.wet = self.shore < 0
        self.fade = 2 / tuning["damping"]
        self.sponge = 3 * c * -math.log(max(tuning["reflection"], 0.02)) / self.rim_width
        self.diffusion = 10 * cell * cell / (math.pi * math.pi)
        self.max_step = 0.5 * cell / (c * math.sqrt(1 + tuning["floor"]))
        self.h = np.zeros((self.ny, self.nx))
        self.u = np.zeros((self.ny, self.nx))  # on each cell's right face
        self.v = np.zeros((self.ny, self.nx))  # on its bottom face

    def press_shape(self, click):
        x, y, radius, _ = click
        return np.exp(-((self.X - x) ** 2 + (self.Y - y) ** 2) / (radius * radius))

    def step(self, dt, click=(0, 0, 1, 0), finger=0.0):
        """One step of dt s; click: the press's centre (px), radius (px) and pressure (px^2/s^2), as
        fluid.frag's uniform; finger: how much of the way down to its resting dent it pushes this step"""
        cell, wet, h, s, d = RIPPLES_CELL, self.wet, self.h, self.shore, self.depth
        g = self.press_shape(click) if click[3] != 0 else None
        p = click[3] * g if g is not None else np.zeros_like(h)

        def faces(axis):
            sl = (slice(None), slice(None, -1)) if axis == 1 else (slice(None, -1), slice(None))
            sr = (slice(None), slice(1, None)) if axis == 1 else (slice(1, None), slice(None))
            old = self.u if axis == 1 else self.v
            both = wet[sl] & wet[sr]
            force = -self.c2 * 0.5 * (d[sl] + d[sr]) * (h[sr] - h[sl]) / cell - (p[sr] - p[sl]) / cell
            sponge = self.sponge * np.clip(1 + 0.5 * (s[sl] + s[sr]) / self.rim_width, 0, 1) ** 2
            new = np.zeros_like(old)
            new[sl] = np.where(both, (old[sl] + dt * force) * np.exp(-(self.fade + sponge) * dt), 0)
            return new

        u, v = faces(1), faces(0)
        left = np.zeros_like(u)
        left[:, 1:] = u[:, :-1]
        top = np.zeros_like(v)
        top[1:, :] = v[:-1, :]
        new = h - dt * ((u - left) + (v - top)) / cell
        # the little diffusion among wet neighbours, from the old heights
        lap = np.zeros_like(h)
        lap[:, 1:] += np.where(wet[:, :-1], h[:, :-1] - h[:, 1:], 0)
        lap[:, :-1] += np.where(wet[:, 1:], h[:, 1:] - h[:, :-1], 0)
        lap[1:, :] += np.where(wet[:-1, :], h[:-1, :] - h[1:, :], 0)
        lap[:-1, :] += np.where(wet[1:, :], h[1:, :] - h[:-1, :], 0)
        new += dt * self.diffusion * lap / (cell * cell)
        new *= math.exp(-LIQUID_LEVEL * dt)
        if g is not None and finger > 0:
            # the finger pushes the surface under it down towards its resting dent (from the heights as the step
            # began, so every cell can tell how much it pushes away), and that liquid goes out to a ring round it
            x, y, radius, pressure = click
            i = int(round(x / cell + 0.5))
            j = int(round(y / cell + 0.5))
            d_press = self.depth[min(max(j, 0), self.ny - 1), min(max(i, 0), self.nx - 1)]
            dent = -pressure * g / (self.c2 * d_press)
            pushed = np.where(wet, np.maximum(h - dent, 0) * finger * g ** 3, 0)
            # what it pushes away, as the shader adds it up: the cells within 1.75 press widths, at most 24 a
            # side, each sample standing for a stride x stride block
            reach = 1.75 * radius
            stride = max(1, int(math.ceil(2 * reach / cell / 24)))
            lo_x, lo_y = int(math.floor((x - reach) / cell + 0.5)), int(math.floor((y - reach) / cell + 0.5))
            hi_x, hi_y = int(math.ceil((x + reach) / cell + 0.5)), int(math.ceil((y + reach) / cell + 0.5))
            total = 0.0
            for qy in range(lo_y, hi_y + 1, stride):
                for qx in range(lo_x, hi_x + 1, stride):
                    if 0 <= qx < self.nx and 0 <= qy < self.ny:
                        total += pushed[qy, qx]
            total *= stride * stride
            r = np.hypot(self.X - x, self.Y - y) / radius
            ring = np.exp(-((r - FINGER_RING) / FINGER_RING_WIDTH) ** 2)
            ring = np.where(ring > 1e-3, ring, 0)
            ring_cells = 2 * math.pi * FINGER_RING * FINGER_RING_WIDTH * math.sqrt(math.pi) * radius * radius / (cell * cell)
            new += total * ring / ring_cells - pushed
        self.h = np.where(wet, new, 0)
        self.u = np.where(wet, u, 0)
        self.v = np.where(wet, v, 0)

    def height_at(self, x, y):
        i = int(round(x / RIPPLES_CELL + 0.5))
        j = int(round(y / RIPPLES_CELL + 0.5))
        if 0 <= i < self.nx and 0 <= j < self.ny:
            return float(self.h[j, i])
        return 0.0


def click_in(tuning):
    return min(max(tuning["clickWidth"] / (0.38 * tuning["speed"]), 0.04), 0.5)


def ease(x, length):
    return math.sin(0.5 * math.pi * min(max(x / length, 0.0), 1.0)) ** 2


class Press:
    """A click as runLiquid presses it: down at `down` s, up at `up` (None: held), following path(t) -> (x, y)"""

    def __init__(self, tuning, path, down=0.0, up=None, finger="moving"):
        self.tuning, self.path, self.down, self.up, self.finger = tuning, path, down, up, finger

    def level(self, t):
        if t < self.down:
            return 0.0
        length = click_in(self.tuning)
        level = ease(t - self.down, length)
        if self.up is not None:
            level *= 1 - ease(t - self.up, length)
        return level

    def uniforms(self, t, dt):
        c = self.tuning["speed"]
        level = self.level(t)
        if level <= 0:
            return (0, 0, 1, 0), 0.0
        x, y = self.path(t)
        pressure = self.tuning["click"] * 0.8 * c * c * self.tuning["clickWidth"] * level
        click = (x, y, self.tuning["clickWidth"], pressure)
        finger = 0.0
        if self.finger != "off":
            outrun = 1.0
            if self.finger == "moving":
                bx, by = self.path(t - 0.02)
                before = self.level(t - 0.02) > 0
                speed = math.hypot(x - bx, y - by) / 0.02 if before else 0.0
                outrun = smooth_step(0.5 * c, 1.5 * c, speed)
            finger = outrun * (1 - math.exp(-dt / CLICK_FINGER))
        return click, finger


def run(liquid, press, until, fps=240.0, start=0.0, every=None):
    """Runs the liquid in frames of 1/fps s as runLiquid does (even steps of at most its maximum), the press
    placed at each step's middle; every(t) after each frame"""
    t = start
    frame = 1.0 / fps
    while t < until - 1e-9:
        span = min(frame, until - t)
        steps = max(1, int(math.ceil(span / liquid.max_step)))
        dt = span / steps
        for k in range(steps):
            click, finger = press.uniforms(t + (k + 0.5) * dt, dt)
            liquid.step(dt, click, finger)
        t += span
        if every:
            every(t)
    return t


def shade(h):
    """the heights as a picture: lit by their slope from the top left, as the glass leans"""
    gy, gx = np.gradient(h, RIPPLES_CELL)
    return np.clip(128 + 110 * (-gx * 0.7 - gy * 0.7), 0, 255).astype(np.uint8)


def save_picture(h, path, marks=()):
    from PIL import Image, ImageDraw
    image = Image.fromarray(shade(h)).resize((h.shape[1] * 3, h.shape[0] * 3), Image.BICUBIC).convert("RGB")
    draw = ImageDraw.Draw(image)
    for x, y in marks:
        cx, cy = (x / RIPPLES_CELL + 0.5) * 3, (y / RIPPLES_CELL + 0.5) * 3
        for a, b in (((-14, 0), (-5, 0)), ((5, 0), (14, 0)), ((0, -14), (0, -5)), ((0, 5), (0, 14))):
            draw.line([(cx + a[0], cy + a[1]), (cx + b[0], cy + b[1])], fill=(255, 80, 40), width=3)
    image.save(path)


def short_ripples(liquid, x, y):
    """The share of the wake's slope (what the glass shows) in waves shorter than 4 cells along the motion,
    8-150 px behind a press moving in +x, 30 px either side of its line: a press that jumps a little each
    step leaves a ripple per step there (0.09-0.13 at 2000 px/s, 60-120 fps, when the finger pressed as hard
    across its whole width; about 0.01 since)"""
    i0 = int(round((x - 150) / RIPPLES_CELL + 0.5))
    i1 = int(round((x - 8) / RIPPLES_CELL + 0.5))
    j = int(round(y / RIPPLES_CELL + 0.5))
    box = liquid.h[max(j - 10, 0):j + 11, max(i0, 0):i1 + 1]
    box = box - box.mean(axis=1, keepdims=True)
    spectrum = np.abs(np.fft.rfft(box * np.hanning(box.shape[1]), axis=1)) ** 2
    k = np.fft.rfftfreq(box.shape[1])
    slope = spectrum * k ** 2
    total = slope.sum()
    return float(slope[:, k > 0.25].sum() / total) if total > 0 else 0.0


def blur(a, sigma):
    k = np.arange(-3 * int(math.ceil(sigma)), 3 * int(math.ceil(sigma)) + 1)
    g = np.exp(-k ** 2 / (2 * sigma * sigma))
    g /= g.sum()
    a = np.apply_along_axis(lambda row: np.convolve(row, g, mode="same"), 1, a)
    return np.apply_along_axis(lambda col: np.convolve(col, g, mode="same"), 0, a)


def frosted_foil(liquid):
    """about what Liquid Glass Light's foil shows of the ripples: lit where they crest, fully from the crest
    runLiquid normalizes a click-only surface's by (0.3 of the press's resting depth at strength 1), then
    frosted (a 12 px blur: thin lines fade, broad crests stay)"""
    crest = 0.3 * 0.8 * liquid.tuning["clickWidth"]
    return blur(np.clip(liquid.h / crest, 0, 1), 12 / RIPPLES_CELL)


def dent_report(liquid, press, t, direction):
    """Along the press's motion through its centre: how far ahead of the press the dent's front edge is (the
    farthest point at least half as deep as the press's resting dent; None: nowhere that deep), where its
    deepest point is, how deep against the resting dent; and short_ripples behind it (direction +x only)"""
    click, _ = press.uniforms(t, liquid.max_step)
    x, y = click[0], click[1]
    dx, dy = direction
    i = int(round(x / RIPPLES_CELL + 0.5))
    j = int(round(y / RIPPLES_CELL + 0.5))
    dent = click[3] / (liquid.c2 * liquid.depth[j, i])
    offsets = np.arange(-90, 41)
    heights = np.array([liquid.height_at(x + dx * o, y + dy * o) for o in offsets])
    deep = offsets[heights < -0.5 * dent]
    front = float(deep.max()) if deep.size else None
    deepest = float(offsets[np.argmin(heights)])
    ripples = short_ripples(liquid, x, y) if direction == (1.0, 0.0) else None
    return dict(front=front, deepest=deepest, depth=float(-heights.min()) / dent, ripples=ripples)


def drag(tuning, speed, finger="moving", width=700, height=560, seed=0.0, fps=240.0, picture=None):
    """a press held 0.1 s, then dragged left to right through the glass's middle at speed px/s, measured as
    it's 100 px from the far side; and how its wake shows through Liquid Glass Light's frost over the last
    40% of the way (well clear of the ring the click sent off as it was pressed)"""
    liquid = Liquid(tuning, width, height, seed=seed)
    x0, y0, hold = 80.0, height / 2, 0.1
    travel = width - 180.0
    until = hold + travel / speed

    def path(t):
        return (x0 + speed * min(max(t - hold, 0.0), travel / speed), y0)

    press = Press(tuning, path, finger=finger)
    wake = [0.0]

    def watch(t):
        if t > hold + 0.6 * travel / speed:
            px = path(t)[0]
            band = (liquid.X > x0 + 0.35 * travel) & (liquid.X < px - 30) & liquid.wet
            if band.any():
                wake[0] = max(wake[0], float(frosted_foil(liquid)[band].max()))

    run(liquid, press, until, fps, every=watch)
    report = dent_report(liquid, press, until - 1e-4, (1.0, 0.0))
    report["wake"] = wake[0]
    if picture:
        save_picture(liquid.h, picture, [path(until)])
    return report


def click(tuning, finger="moving", hold=0.25, width=700, height=560, seed=0.0, fps=240.0, ring=70.0):
    """a plain click in the glass's middle, held `hold` s: the largest wave on a circle `ring` px out while
    it's held, and after it's let go"""
    liquid = Liquid(tuning, width, height, seed=seed)
    cx, cy = width / 2, height / 2
    press = Press(tuning, lambda t: (cx, cy), up=hold, finger=finger)
    on_ring = np.abs(np.hypot(liquid.X - cx, liquid.Y - cy) - ring) < 3
    peaks = {"pressed": 0.0, "let go": 0.0}

    def measure(t):
        key = "pressed" if t <= hold else "let go"
        peaks[key] = max(peaks[key], float(np.abs(liquid.h[on_ring]).max()))

    run(liquid, press, hold + 0.65, fps, every=measure)
    return peaks


def fmt_front(front):
    return "nowhere half as deep" if front is None else f"{front:+5.1f} px"


def cmd_drag(args, tuning):
    speeds = args.speeds or [300, 700, 1300, 2000]
    print(f"speed {tuning['speed']:g} px/s, press {tuning['click']:g} x {tuning['clickWidth']:g} px, {args.fps:g} fps; "
          "the dent's front edge sits about +12 px from a still press")
    for finger in (["off", "moving"] if args.finger == "both" else [args.finger]):
        for speed in speeds:
            picture = os.path.join(args.png, f"drag-{finger}-{speed:g}.png") if args.png else None
            r = drag(tuning, speed, finger, args.width, args.height, args.seed, args.fps, picture)
            print(f"  finger {finger:6s} {speed:6g} px/s: front edge {fmt_front(r['front'])}, deepest {r['deepest']:+5.0f} px, "
                  f"depth {r['depth']:.2f} of resting, short ripples behind {r['ripples']:.4f}, wake through the frost {r['wake']:.2f}")
    return 0


def cmd_click(args, tuning):
    for finger in (["off", "moving", "always"] if args.finger == "both" else [args.finger]):
        peaks = click(tuning, finger, args.hold, args.width, args.height, args.seed, args.fps)
        print(f"  finger {finger:6s}: ring 70 px out, as it's pressed {peaks['pressed']:.2f} px, as it's let go {peaks['let go']:.2f} px")
    return 0


def cmd_check(args, tuning):
    failures = 0

    def verdict(ok, text):
        nonlocal failures
        failures += 0 if ok else 1
        print(f"  [{'PASS' if ok else 'FAIL'}] {text}")

    print(f"tuning: speed {tuning['speed']:g}, press {tuning['click']:g} x {tuning['clickWidth']:g} px")
    # the slowest screens step the liquid least often for a frame, so a moving press jumps furthest there
    for fps in (60, 240):
        for speed in (700, 1300, 2000):
            r = drag(tuning, speed, "moving", seed=args.seed, fps=fps)
            where = f"{speed} px/s, {fps} fps"
            verdict(r["front"] is not None and r["front"] >= -3, f"{where}: the dent keeps up (front edge {fmt_front(r['front'])}, at least -3 px)")
            verdict(r["depth"] >= 0.6, f"{where}: the dent stays deep ({r['depth']:.2f} of resting, at least 0.60)")
            verdict(r["ripples"] <= 0.03, f"{where}: no ripple per step behind it (short ripples {r['ripples']:.4f}, at most 0.03)")
            if speed >= 1300:
                verdict(r["wake"] >= 0.5, f"{where}: its wake shows through Liquid Glass Light's frost ({r['wake']:.2f}, at least 0.50)")
    off = click(tuning, "off", seed=args.seed, fps=args.fps)
    on = click(tuning, "moving", seed=args.seed, fps=args.fps)
    for key in ("pressed", "let go"):
        verdict(abs(on[key] - off[key]) <= 0.05 * off[key] + 1e-6,
                f"a plain click's ring as it's {key} as without the finger ({on[key]:.2f} px against {off[key]:.2f})")
    print("check passed" if not failures else f"check failed: {failures}")
    return 1 if failures else 0


def read_log(directory):
    log = {"tuning": None, "steps": [], "frames": [], "downs": [], "ups": [], "samples": []}
    with open(os.path.join(directory, "log")) as f:
        for line in f:
            w = line.split()
            # a line cut short (the preview's KWin is killed, mid-write, as it ends) is left out
            if not w or len(w) < {"tuning": 3, "step": 8, "frame": 12, "down": 4, "up": 2, "sample": 4}.get(w[0], 1):
                continue
            if w[0] == "tuning":
                log["tuning"] = {w[k]: float(w[k + 1]) for k in range(1, len(w) - 1, 2)}
            elif w[0] == "step":
                log["steps"].append(tuple(float(x) for x in w[1:8]))
            elif w[0] == "frame":
                log["frames"].append(dict(n=int(w[1]), t=float(w[2]), width=float(w[3]), height=float(w[4]),
                                          corners=tuple(float(x) for x in w[5:9]), seed=float(w[9]), tw=int(w[10]), th=int(w[11])))
            elif w[0] == "down":
                log["downs"].append(tuple(float(x) for x in w[1:4]))
            elif w[0] == "up":
                log["ups"].append(float(w[1]))
            elif w[0] == "sample":
                log["samples"].append(tuple(float(x) for x in w[1:4]))
    return log


def cmd_compare(args, _):
    log = read_log(args.dir)
    if not log["frames"] or not log["steps"]:
        print(f"error: no frames or steps in {args.dir}/log (was KWIN_LIQUID_GLASS_CLICK_LOG set for the preview's KWin?)", file=sys.stderr)
        return 2
    tuning = {key: float(spec[0]) for key, spec in TUNING.items()}
    tuning.update(log["tuning"] or {})
    first = log["frames"][0]
    liquid = Liquid(tuning, first["width"], first["height"], first["corners"], first["seed"])
    frames = iter(log["frames"])
    frame = next(frames)
    errors = []
    pictures = set(args.png_frames or [])
    for t, dt, x, y, radius, pressure, finger in log["steps"]:
        while frame is not None and frame["t"] < t:
            errors.append(compare_frame(liquid, frame, args, pictures))
            frame = next(frames, None)
        liquid.step(dt, (x, y, radius, pressure), finger)
    while frame is not None:
        errors.append(compare_frame(liquid, frame, args, pictures))
        frame = next(frames, None)
    errors = [e for e in errors if e is not None]
    if not errors:
        print("no frames to compare")
        return 2
    # frames the click has stirred: before that, the real liquid can hold ripples from before the log (a popup
    # sliding in), which the model starts without
    peak = max(e[2] for e in errors)
    stirred = [e for e in errors if e[2] >= 0.1 * peak]
    rel = np.array([e[1] for e in stirred])
    worst = stirred[int(np.argmax(rel))]
    print(f"{len(stirred)} frames the click stirred (of {len(errors)}): the model's heights differ from the real liquid's by "
          f"{np.median(rel) * 100:.1f}% of its spread (median; worst {worst[1] * 100:.1f}% at frame {worst[0]})")
    if args.verbose:
        for n, r, rms in errors:
            print(f"  frame {n}: {r * 100:5.1f}% (real rms {rms:.2f} px)")
    return 0


def compare_frame(liquid, frame, args, pictures):
    path = os.path.join(args.dir, f"{frame['n']:05d}.f32")
    if not os.path.exists(path):
        return None
    real = np.fromfile(path, dtype=np.float32).reshape(frame["th"], frame["tw"])[: liquid.ny, : liquid.nx]
    model = liquid.h[: real.shape[0], : real.shape[1]]
    rms = float(np.sqrt((real ** 2).mean()))
    if rms < 1e-3:
        return None
    if frame["n"] in pictures:
        from PIL import Image
        a = os.path.join(args.dir, f"real-{frame['n']:05d}.png")
        b = os.path.join(args.dir, f"model-{frame['n']:05d}.png")
        Image.fromarray(shade(real)).save(a)
        Image.fromarray(shade(model)).save(b)
        print(f"  frame {frame['n']}: {a}, {b}")
    return frame["n"], float(np.sqrt(((model - real) ** 2).mean())) / rms, rms


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--config", default=os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "plasma-glassrc"),
                        help="plasma-glassrc to take [Ripple] from (default: yours)")
    parser.add_argument("--fps", type=float, default=240, help="the frames the liquid runs in (default 240)")
    parser.add_argument("--seed", type=float, default=0, help="the shore's and floor's shape (runLiquid takes it from when the window opened)")
    parser.add_argument("--width", type=float, default=700, help="the glass, px (default 700 x 560, about Kickoff's)")
    parser.add_argument("--height", type=float, default=560)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("drag", help="straight drags at SPEED px/s")
    p.add_argument("speeds", nargs="*", type=float)
    p.add_argument("--finger", choices=["off", "moving", "always", "both"], default="both",
                   help="the finger as the effect has it (moving: as the press outruns the waves), off, always, or off and moving (default)")
    p.add_argument("--png", help="a picture of each drag's liquid into this folder")
    p = sub.add_parser("click", help="a plain click's rings")
    p.add_argument("--hold", type=float, default=0.25)
    p.add_argument("--finger", choices=["off", "moving", "always", "both"], default="both")
    sub.add_parser("check", help="drag and click against what they should do")
    p = sub.add_parser("compare", help="the model on a KWIN_LIQUID_GLASS_CLICK_LOG log, against the real liquid")
    p.add_argument("dir")
    p.add_argument("--png", dest="png_frames", type=int, nargs="*", help="pictures of these frames, real and model, into DIR")
    p.add_argument("-v", "--verbose", action="store_true", help="every frame's difference")
    args = parser.parse_args()
    tuning = read_tuning(args.config)
    return {"drag": cmd_drag, "click": cmd_click, "check": cmd_check, "compare": cmd_compare}[args.command](args, tuning)


if __name__ == "__main__":
    sys.exit(main())
