# Preview harness

Screenshots of KRunner and Plasma dialogs with a given Plasma Style, without touching your desktop.
Each run starts a virtual KWin display on its own D-Bus session, with throwaway copies of your Plasma
config (your Liquid Glass tuning, `plasma-glassrc`, included) and a private data dir. Nothing appears on screen, nothing takes keyboard focus, and your real
settings and services are left alone. Background services the session starts are stopped at the end.

```sh
tools/preview/krunner.sh /tmp/krunner.png "beurre blanc sauce"   # KRunner with a query
tools/preview/dialog.sh /tmp/dialog.png                          # notification-like dialog
tools/preview/record.sh /tmp/ripple.mp4 "system settings"        # video of KRunner while busy
tools/preview/panel.sh /tmp/panel.mp4                            # your panel floating, docking, floating
tools/preview/elements.sh translucent/dialogs/background topleft top center hint-top-margin
STYLE=default tools/preview/elements.sh widgets/scrollbar slider-topleft     # same, for Breeze
```

By default the style comes from this checkout: `theme/liquid-glass/generate.py` is regenerated into
the private data dir on every run, so you can preview edits before installing them: Liquid Glass, or
with `STYLE=repo-light` or `STYLE=repo-dark-frost`, Light or Dark Frost. `STYLE=<id>` previews an
installed style instead. `WALLPAPER=path` and `WIDTH`/`HEIGHT`/`SCALE` change the
backdrop and virtual screen; see [`common.sh`](common.sh). `KWIN_ENV` passes extra environment to the
preview's KWin only, e.g. `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`
to composite on the Intel iGPU instead of the NVIDIA card.
`KWIN_WAYLAND=path` runs a development build of KWin instead of the installed one (see AGENTS.md),
and `WALLPAPER_PAN=40` scrolls the wallpaper at 40 px/s, so what's behind the glass moves and KWin
redraws its blur every frame (for `record.sh`; screenshots crop to everything that changed).

| Command | What it does |
|---|---|
| `krunner.sh` | Uses your `krunnerrc` and the installed KRunner (so it shows patched builds). If KRunner calls the semantic search service, a second, read-only copy starts inside the preview; it never re-indexes, so it can't race the real service. Results come out cropped to the KRunner window. `SWITCH="FROM TO"` (global theme ids) starts it on FROM and applies TO with the results showing, as KDE's Dark Mode switch does, for bugs that only show after a switch; `OUT-before.png` is just before. |
| `settings.sh` | System Settings opened on a page with arguments, as KRunner's System Settings results open it (`settings.sh OUT.png kcm_keys "kwin Maximize Window"`), sized 1240x760. `ARGS2` then sends other arguments to the open page (`OUT-before.png` is just before), `SYSTEMSETTINGS_ENV="QT_PLUGIN_PATH=$(tools/patch-dev.sh kcm-keys)"` loads a dev build of the Shortcuts page. The preview's KWin runs with global shortcuts here (its own, and apps' launch keys from their .desktop files, with your keys from a copy of your `kglobalshortcutsrc`), so the Shortcuts page has some to list; `SHORTCUTS=1` turns them on for the other scripts too (KRunner's System Settings results and Global Shortcuts runner list them; `KRUNNER_ENV="QT_PLUGIN_PATH=$(tools/patch-dev.sh kcm-keys)"` loads a dev build of that runner). |
| `dialog.sh` | A `PlasmaCore.Dialog` with a header, search field, highlighted row and scrolling body. A plain `qml6` client can't position Plasma dialogs (KWin reserves that for Plasma itself), so it opens top-left. Plasma then leaves out the top and left frame edges, and the script moves the window into view with KWin. The right and bottom edges, padding and content are accurate. |
| `popup.sh` | A real plasmashell with a system tray, opening one tray popup (`volume` or `clipboard`; with `PANEL=mine`, your own panels and any tray applet), or showing the sample notifications (`notify`). Prints the QML warnings plasmashell logged while running and while quitting. Its private bus can only start the activity manager, so no second kded, KDE Connect or powerdevil runs next to yours. |
| `panel.sh` | Your panel (a copy of your layout and plasmashellrc) in a real plasmashell, as popup.sh runs it, cropped to the screen's bottom: floating, or docked (`DOCK=1`: an ordinary window is maximized, so a floating panel docks, as on your desktop). With `OUT.mp4` it records the panel floating, docking as the window maximizes (`MAX_AT`, 1.5 s) and floating again as it's restored (`RESTORE_AT`, 4.5 s). `COLORS=BreezeDark` applies a colour scheme for the dark style, `FLOATING=0` sets the panel not to float, `POPUP=kickoff` opens an applet's popup (raise `CROP`), and `PLASMASHELL`/`SHELL_PACKAGE` run a dev plasmashell and an edited desktop package (Panel.qml). The screen is 1600x1000 at scale 1. |
| `drag.sh` | Meta+drags KRunner from one virtual screen onto the next (two outputs) with `fakeinput.c` and prints its geometry and output after every move, then the saved position; the screenshot shows whether the query and results came along. `TYPE="30 31"` types keys afterwards, `DRAG_STEPS` sets the distance. |
| `record.sh` | A video of KRunner with results for a query and its busy feedback running (`BUSY=0` for none): its window plus `PAD` px, `SECONDS_CAPTURED` long (default 6), 60 fps, captured through KWin's `CaptureArea` on a 120 Hz virtual screen, so every frame shows KRunner as it was at most 8 ms before. Writes `OUT.mp4` and keeps a lossless `OUT.mkv` for cuts and side-by-sides. `QUERY2` (sent `QUERY2_AT` s in, default 2) records the results changing, or unfolding from a query of `""`. The window is measured `HOLD` s (default 3) after the first query: results that come later (the search service's, started cold) can grow it past the crop, so give a bigger `PAD` and crop afterwards. |
| `frametimes.sh` | Dropped frames while KRunner's dropdown folds and unfolds: `frametimes.sh OUTDIR` types "f" and Backspace three times, `STEP` ms apart (1500), while KWin logs every frame (`KWIN_LOG_PERFORMANCE_DATA`) and a KWin script times each of KRunner's resizes; `frametimes.py` prints, for each fold and unfold, the steps that came more than 1.5 frames late and the vblanks KWin skipped. `NOGLASS=1` puts the built-in blur in place of the Liquid Glass effect. No capture, so it doesn't load the machine itself: run it where the frames drop (the laptop). |
| `fakeinput.c` | Pointer input for the virtual display (`move X Y`, `by DX DY`, `down`, `up`, `key CODE down|up`, `wait MS` on stdin), built by `common.sh`'s `fakeinput`. KWin scripts can print window geometry alongside, to measure drags. |
| `elements.sh` | Prints each SVG element's rect exactly as Plasma measures it. Frame pieces must come out at whole-pixel sizes; a stroke on an outline adds half a pixel and leaves gaps in the frame. |

For the liquid under the glass (clicks, drags), [`tools/liquid/`](../liquid/README.md) has a numpy model of it, and
`tools/liquid/record.sh` runs `panel.sh` with the effect logging every liquid step to check the model against.

Requirements: `kwin_wayland`, `spectacle`, `qml6` and `qdbus6` (all part of Plasma 6), and `ffmpeg`
for `record.sh`. A small Pillow venv for cropping is created in `~/.cache/plasma-glass/preview/` on
first use, and logs from each run go there too.
