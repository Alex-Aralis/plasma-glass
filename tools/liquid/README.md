# Liquid model

A numpy model of the Liquid Glass effect's liquid, for trying and testing changes to it without KWin. It runs
`kwin-effect/shaders/fluid.frag`'s ripples layer cell for cell as the GPU does: the shallow water on its
staggered grid, the shore and floor shaped by the same patterns, the sponge along the rim, a click's press
and its finger. It uses `runLiquid`'s step sizes and your `[Ripple]` tuning from `~/.config/plasma-glassrc`.
Not modelled: KRunner's busy pushes and breeze, the swell layer and the window's momentum, and the surface and
glass drawn over the liquid.

```sh
tools/liquid/liquid.sh check                 # drags and a click against what they should do; exit 1 if not
tools/liquid/liquid.sh drag 700 2000         # where a dragged press's dent is, with and without the finger
tools/liquid/liquid.sh click                 # a plain click's rings as it's pressed and let go
tools/liquid/record.sh /tmp/liquid           # drags in the preview with the real effect, logged (about 30 s)
tools/liquid/liquid.sh compare /tmp/liquid   # the model on that log, against the real liquid
```

`liquid.sh` runs `liquid.py` in a venv with numpy and Pillow, made in `~/.cache/plasma-glass/liquid/` on first
use. Every command takes `--config` (another plasma-glassrc), `--fps` (the frames the liquid runs in, 240 by
default), `--seed` (the shore's and floor's shape) and `--width`/`--height` (the glass, 700 x 560 px by
default, about Kickoff's).

| Command | What it does |
|---|---|
| `drag [SPEED...]` | Presses for 0.1 s, then drags straight across the glass at each speed (px/s), and measures as the press nears the far side. It reports how far ahead of the press the dent's front edge is (the farthest point at least half as deep as the press's resting dent; about +12 px for a still press), where its deepest point is, how deep it is against the resting dent, and the share of the wake's slope in waves under 4 cells long ("short ripples": a press that jumps a little each step leaves a ripple per step). `--finger off\|moving\|always\|both` (both: off and moving, the default) and `--png DIR` for a picture of each drag's liquid, shaded by slope, the press marked. |
| `click` | A plain click held 0.25 s (`--hold`): the largest wave on a circle 70 px out while it's held, and after it's let go. |
| `check` | Drags at 700, 1300 and 2000 px/s at 60 and 240 fps, and a click. It passes if the dent keeps up (front edge at least -3 px), stays at least 0.6 as deep as at rest, leaves short ripples of at most 0.03, and the click rings as it would without the finger (within 5%). Each limit is set to fail on a change that was tried and dropped: no finger fails the first (-15 px at 700 px/s), the finger pressing as hard across its whole width fails the third (0.13 at 2000 px/s, 60 fps), and the finger on for a still press fails the last (half the ring as it's pressed). |
| `compare DIR` | Replays a click log's liquid steps in the model, with the logged glass, shape and tuning, and holds it against the real liquid read back each frame. It prints the median and worst difference as a share of the real liquid's spread. Frames before the click stirred the liquid are left out, since the real liquid may still carry ripples from before the log, such as a popup sliding in. `--png N...` writes `real-N.png` and `model-N.png` into DIR, and `-v` lists every frame. |

`record.sh DIR ["X1 Y1 X2 Y2 MS, ..."]` runs `tools/preview/panel.sh` with this checkout's effect
(`KWIN_EFFECT=repo`) and Kickoff open. `KWIN_LIQUID_GLASS_CLICK_LOG=DIR` goes to the preview's KWin, and the
fake pointer drags across Kickoff, by default at about 700, 1300 and 2000 px/s. `DIR/glass.mp4` shows the glass
as it ran. The preview's own settings work as in `tools/preview/README.md` (run as the claude account, it needs
`XDG_RUNTIME_DIR` and the Mesa EGL vendor set, as AGENTS.md says).

## The click log

With `KWIN_LIQUID_GLASS_CLICK_LOG=DIR` in its environment, the effect writes these lines to `DIR/log`:
- `tuning ...`, the liquid's tuning as a click lands;
- `down T X Y`, `sample T X Y` and `up T` for the press and the pointer's path, with the input events' times
  (s, monotonic) and px in the glass from its top left;
- `step T DT X Y RADIUS PRESSURE FINGER` for every ripples step of the last-clicked window's liquid, with its
  middle's time, its length and the `click` and `clickFinger` uniforms as `fluid.frag` gets them;
- `frame N T WIDTH HEIGHT TL TR BL BR SEED TEXW TEXH` after each frame's steps while a click presses, with
  `DIR/N.f32` holding the ripples' heights read back from the GPU (TEXW x TEXH floats, row by row from the
  top, cell (i, j) at ((i - 0.5) 3, (j - 0.5) 3) px).

Unset, the effect writes and reads back nothing. The readback stalls the GPU each frame, so leave it off
outside the preview.

Keep `liquid.py` in step with `fluid.frag` and `runLiquid` (the constants at its top, `Liquid.step` and
`Press.uniforms`). After changing either, `record.sh` and `compare` show whether they still agree: they
agreed to 0.8% of the liquid's spread when this was written.
