# Preview harness

Screenshots of KRunner and Plasma dialogs with a given Plasma Style, without touching your desktop.
Each run starts a virtual KWin display on its own D-Bus session, with throwaway copies of your Plasma
config and a private data dir. Nothing appears on screen, nothing takes keyboard focus, and your real
settings and services are left alone. Background services the session starts are stopped at the end.

```sh
tools/preview/krunner.sh /tmp/krunner.png "beurre blanc sauce"   # KRunner with a query
tools/preview/dialog.sh /tmp/dialog.png                          # notification-like dialog
tools/preview/record.sh /tmp/ripple.mp4 "system settings"        # video of KRunner while busy
tools/preview/elements.sh translucent/dialogs/background topleft top center hint-top-margin
STYLE=default tools/preview/elements.sh widgets/scrollbar slider-topleft     # same, for Breeze
```

By default the style comes from this checkout: `theme/liquid-glass/generate.py` is regenerated into
the private data dir on every run, so you can preview edits before installing them. `STYLE=<id>`
previews an installed style instead. `WALLPAPER=path` and `WIDTH`/`HEIGHT`/`SCALE` change the
backdrop and virtual screen; see [`common.sh`](common.sh). `KWIN_ENV` passes extra environment to the
preview's KWin only, e.g. `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`
to composite on the Intel iGPU instead of the NVIDIA card.

| Command | What it does |
|---|---|
| `krunner.sh` | Uses your `krunnerrc` and the installed KRunner (so it shows patched builds). If KRunner calls the semantic search service, a second, read-only copy starts inside the preview; it never re-indexes, so it can't race the real service. Results come out cropped to the KRunner window. |
| `dialog.sh` | A `PlasmaCore.Dialog` with a header, search field, highlighted row and scrolling body. A plain `qml6` client can't position Plasma dialogs (KWin reserves that for Plasma itself), so it opens top-left. Plasma then leaves out the top and left frame edges, and the script moves the window into view with KWin. The right and bottom edges, padding and content are accurate. |
| `popup.sh` | A real plasmashell with a system tray, opening one tray popup (`volume` or `clipboard`; with `PANEL=mine`, your own panels and any tray applet), or showing the sample notifications (`notify`). Prints the QML warnings plasmashell logged while running and while quitting. Its private bus can only start the activity manager, so no second kded, KDE Connect or powerdevil runs next to yours. |
| `drag.sh` | Meta+drags KRunner from one virtual screen onto the next (two outputs) with `fakeinput.c` and prints its geometry and output after every move, then the saved position; the screenshot shows whether the query and results came along. `TYPE="30 31"` types keys afterwards, `DRAG_STEPS` sets the distance. |
| `record.sh` | A video of KRunner with results for a query and its busy feedback running (`BUSY=0` for none): its window plus `PAD` px, `SECONDS_CAPTURED` long (default 6), 60 fps, captured through KWin's `CaptureArea` on a 120 Hz virtual screen, so every frame shows KRunner as it was at most 8 ms before. Writes `OUT.mp4` and keeps a lossless `OUT.mkv` for cuts and side-by-sides. |
| `fakeinput.c` | Pointer input for the virtual display (`move X Y`, `by DX DY`, `down`, `up`, `key CODE down|up`, `wait MS` on stdin), built by `common.sh`'s `fakeinput`. KWin scripts can print window geometry alongside, to measure drags. |
| `elements.sh` | Prints each SVG element's rect exactly as Plasma measures it. Frame pieces must come out at whole-pixel sizes; a stroke on an outline adds half a pixel and leaves gaps in the frame. |

Requirements: `kwin_wayland`, `spectacle`, `qml6` and `qdbus6` (all part of Plasma 6), and `ffmpeg`
for `record.sh`. A small Pillow venv for cropping is created in `~/.cache/plasma-glass/preview/` on
first use, and logs from each run go there too.
