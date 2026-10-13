# plasma-glass: notes for development

Liquid Glass Plasma Styles, semantic KRunner search (EmbeddingGemma 2 on the Intel iGPU via OpenVINO)
and Portage patches for KRunner, notification popups, milou and Qt's Wayland client. Gentoo, Plasma
6.7.5, Qt 6.11.2, Wayland. User
docs are in README.md; this file covers how to work on it.

## Layout

| Path | What |
|---|---|
| `search/embedsearch.py` | search service: indexer, KRunner D-Bus runner (`local.embedsearch`), CLI. Installed copy: `~/.local/share/embedsearch/` (service `embedsearch.service`) |
| `search/export_model.py` | one-time PyTorch to OpenVINO export with a parity check (run by install.sh in a throwaway venv) |
| `theme/liquid-glass/generate.py` | draws both styles (`liquid-glass`, `liquid-glass-light`) into `~/.local/share/plasma/desktoptheme/` |
| `patches/kde-plasma/{plasma-workspace,milou}/*.patch`, `patches/dev-qt/qtbase/*.patch` | Portage user patches, one per package |
| `desktop/` | KRunner plugin, systemd and D-Bus files, `plasma-settings.sh` (krunnerrc, kdeglobals, plasmanotifyrc) |
| `tools/patch-dev.sh` | patch workflow: setup, edit, check, refresh, install; `krunner` and `qt` build test copies |
| `tools/check-patches.sh` | patches apply; patched QML loads under qml6 with stubs; patched KRunner C++ syntax-checks |
| `tools/preview/` | screenshots on a virtual KWin display: `krunner.sh`, `dialog.sh`, `popup.sh` (a real plasmashell tray popup), `elements.sh`; `unfold.sh` measures KRunner's resize animation frame by frame (`frames.py`); `fakeinput.c` for pointer input |
| `desktop/test-notifications.sh` | sample popups (clickable, long and scrolling, image, critical); installed as `plasma-glass-test-notifications` with a "Test Notifications" launcher |

## Dev loops

- **Style:** edit `generate.py`, then `tools/preview/krunner.sh /tmp/k.png "query"` (or
  `STYLE=repo-light`). Apply with `./install.sh --no-search --no-settings`, which regenerates the SVGs,
  drops Plasma's cached renders and reapplies.
- **Patches:** `tools/patch-dev.sh setup`, edit under `~/.cache/plasma-glass/dev/b/<pkg>/`, then
  `refresh` and `check`, then `sudo tools/patch-dev.sh install`. After the build, run
  `systemctl --user restart plasma-plasmashell.service` (notifications) and `kquitapp6 krunner`.
  For notification changes, run `plasma-glass-test-notifications` and check
  `journalctl --user -u plasma-plasmashell.service` for QML errors. The real popups only appear in
  plasmashell, so the user looks at them; `tools/preview/dialog.sh` only approximates them.
  milou rebuilds in about 2 min, plasma-workspace in about 25 min on the laptop (about 6 min on the
  main box).
- **KRunner C++/QML without an emerge:** `tools/patch-dev.sh krunner` builds just KRunner from the
  edited tree (about 20 s the first time, then seconds) and refreshes a milou QML overlay. Preview:
  `QML_IMPORT_PATH=~/.cache/plasma-glass/dev/qml KRUNNER=$(tools/patch-dev.sh krunner) tools/preview/krunner.sh /tmp/k.png "q"`.
  `tools/preview/fakeinput.c` (built by `common.sh`) sends pointer input to the preview's KWin, and a
  KWin script can print `frameGeometry` of each window, so drags can be measured, not just eyeballed.
- **Qt's Wayland client without an emerge:** `tools/patch-dev.sh setup qtbase`, edit under
  `~/.cache/plasma-glass/dev/b/qtbase/src/plugins/platforms/wayland/`, then `tools/patch-dev.sh qt`
  (about 2 min the first time, then seconds) builds libQt6WaylandClient, the wayland platform
  plugin and its EGL plugin, and prints the environment that loads them into one app:
  `KRUNNER_ENV="$(tools/patch-dev.sh qt) QT_QUICK_BACKEND=software" tools/preview/unfold.sh`. The
  build is configured from the installed qtbase's USE flags like the ebuild, and the tool refuses
  to stage it unless its generated feature headers match the installed ones (one mismatch,
  AT-SPI on, gave `undefined symbol: QSpiAccessibleBridge` at startup). Only libQt6WaylandClient
  and the plugins are swapped in, with the build tree's RUNPATH removed so the installed QtCore and
  QtGui are used.
- **Resize glitches:** `tools/preview/unfold.sh` captures ~150 fps while KRunner's results unfold
  and fold and prints `top edge misplaced in N` (old frame shifted) and `N distinct text layouts`
  (old frame stretched; 1 = clean). `KRUNNER=`, `KRUNNER_ENV=` and `KWIN_ENV=` pick the build and
  environment. The stretch comes and goes, so compare several runs. Main box (KWin on NVIDIA),
  2026-10-12: GPU rendering on NVIDIA 22-29 misplaced, 14-16 layouts (the shifts count as layouts
  too), with stock or patched Qt; software rendering with stock Qt 0 misplaced, 1-9 layouts
  (stretched in 5 of 6 runs), with the Qt patch 1 layout in 10 of 10; Mesa GPU rendering
  (`__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`) 1-2 misplaced and
  5 layouts with stock Qt, 1 layout with the patch.
- **Search:** edit `search/embedsearch.py`, copy it to `~/.local/share/embedsearch/`, then
  `systemctl --user restart embedsearch`. Use `embedsearch search "q"` to test.

## Rules learned the hard way

- **Run `tools/check-patches.sh` before every emerge.** qmllint misses runtime-only QML errors.
  Example: `background: Item {}` together with the existing `background.z: -2` ("Cannot assign a
  value directly to a grouped property") built fine and then KRunner's UI failed to load.
- **Never open KRunner or dialogs on the real screen to look at them.** They take keyboard focus
  from the user. Use `tools/preview/`, which runs a private bus and display. Its services get the
  virtual `WAYLAND_DISPLAY` and no `DISPLAY`, and leftovers on the private bus are killed at the end.
- **Plasma measures SVG elements by bounding box, strokes included.** Build frame pieces from fills
  inside exact tile rects (see `tile()` in generate.py). Check with `tools/preview/elements.sh`, where
  every piece must be whole pixels. Use `hint-stretch-borders`, since tiled edges leave seams at
  fractional scales.
- **Declare zero insets on dialogs/background** (`hint-*-inset`, as Breeze does). Without them
  PlasmoidHeading sizes itself from `widgets/plasmoidheading` margins, which depend on its own
  position, and plasmashell logged `Binding loop detected for property "leftInset"` while tearing
  popups down (on every restart, not start). `tools/preview/popup.sh` prints warnings from running
  and from quitting separately; `PANEL=mine` uses your real panel and tray.
- **Plasma caches style renders** in `~/.cache/plasma_theme_<id>.kcache`. Switch to another style,
  delete the cache, then switch back.
- **KRunner is a layer-shell surface.** KWin can't move it, and Wayland clients never learn their
  position. KRunner places itself with layer margins (`View::applyFloatingMargins`, keys
  `FloatingTop`/`FloatingCenterX`). Test dialogs from `qml6` can't place themselves either (KWin
  reserves plasma-shell), so `dialog.sh` shows them without top/left frame edges.
- **Pointer positions in a layer-shell window lag its moves.** Events are window-local, and the
  compositor applies new margins some events later, so "move by the offset from the press point"
  feeds back on itself (a 100 px drag flew to the screen edge). KRunner's drag follows
  `zwp_relative_pointer_v1` motion instead, with the virtual pointer clamped to the screen like the
  real cursor.
- **Layer-shell margins only apply on a commit.** layer-shell-qt's `setMargins` just sends
  `set_margin`; `requestUpdate()` doesn't render an unchanged scene, so nothing commits. Use
  `QQuickWindow::update()`.
- **KWin compositing on NVIDIA misplaces a resizing layer-shell window for a frame:** it applies
  the new size before the new buffer, so on each step of the results' unfold KRunner's old frame
  showed at the new size (pushed down when growing, up and clipped when shrinking): jumps and
  ghosts. Not with KWin on the iGPU. With KRunner's software renderer (`QT_QUICK_BACKEND=software`,
  CPU shm buffers) the frame was stretched instead (text flicker), in 3 of 4 runs: Qt sent the new
  `wp_viewporter` destination before the buffer that matches it (fixed by the Qt patch, below). Also setting
  `QT_WAYLAND_DISABLED_INTERFACES=wp_viewporter,wp_fractional_scale_manager_v1` made it clean in 6 of
  6 (fine at scale 1; fractional scales would render at the next whole scale). install.sh adds both
  as a `plasma-krunner.service` drop-in when KWin's GL vendor is NVIDIA (just the first once the
  patched Qt is installed). Check animations by text
  positions too, not just edges: a stretch keeps the top edge in place. Found by
  capturing frames from the preview KWin at ~150 fps: start it with
  `KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1` and call `org.kde.KWin.ScreenShot2.CaptureActiveScreen`
  in a loop (dbus-fast: the `h` argument is the index into `unix_fds`; raw BGRA, format 6).
- **`Kirigami.Icon` rounds to standard sizes** (`roundToIconSize`): ask for 28 px and you get 22.
- **QQuickWindow sees every press as accepted after delivery**, even on empty space. Handle input
  in QML, as the KRunner drag area does (a MouseArea under the content).
- **KRunner's results model ends every refresh with `layoutChanged`**, which makes ListView recreate
  all rows. Per-row add transitions replay on every keystroke; that's why only the panel unfold is
  animated.
- **Similarity scores are compressed** (junk about 0.65, real matches about 0.7), so there's no
  junk threshold. Show the top N.
- **Model export:** needs `torchvision` (the processor imports Gemma 4 image code) and
  transformers 5.19 or later. Installing `sentence-transformers[image,audio]` downgraded
  transformers once.
- **Intel's GPU compiler hijacks signals.** `libigdfcl` (IGC, legacy runtime) installs a handler
  that longjmps back into its compiler and leaves it in place after runtime kernel compiles, so a
  later SIGTERM aborted the service with a core dump. `take_signals()` blocks TERM/INT/HUP before
  numpy starts its threads and takes them with `sigwait`; launch apps with `launch()` so they don't
  inherit the mask.
- **OpenVINO telemetry is opt-out:** `import openvino` sends a Google Analytics event through a
  spawned process unless `~/intel/openvino_telemetry` contains `0` (install.sh writes it).
- **KRunner sends Teardown before Run** when a result is clicked (it ends the session as the
  window hides), so a D-Bus runner must keep its matches until the next session's Match.
- **Qt sent the `wp_viewporter` destination as soon as a window resized** (`setGeometry_helper`),
  but it only applies with a commit, and the next commit can still carry the old buffer (a frame
  rendered before the resize) or none at all (an ack or a blur-region update), so the compositor
  stretched the old frame to the new size. `qtbase-wayland.patch` sends it with each buffer instead:
  from the buffer's size in `attach()` (shm), and in `QWaylandGLContext::swapBuffers` from
  `eglQuerySurface(EGL_WIDTH/HEIGHT)` (the driver applies `wl_egl_window_resize` between frames, so
  that size can lag the geometry; Mesa, egl-wayland and egl-wayland2 all report the back buffer's
  size). Vulkan windows still send it on resize (the driver presents). Qt only creates a viewport
  when the compositor has fractional scaling, which KWin does.
- **Shell:** `grep` may be ugrep (`$` mid-pattern differs), and this session's `grep` wrapper
  skips binary files (use `/bin/grep` on a .so). Never nest a here-doc whose body contains its own
  delimiter. Claude Code's safety check refuses `rm -rf "$VAR/x"`, even inside a script being
  written; write `"${VAR:?}/x"`.

## Machines

- **Laptop (t14):** i5-1245U, Iris Xe (Gen12.3), `intel-compute-runtime:legacy` (works on Gen12
  despite Gentoo's note). GPU f16 runs about 2,000 tokens/s for indexing and about 40 ms per query.
- **Main box:** i9-14900K, UHD 770 (Raptor Lake-S GT1, Gen12) plus an RTX 2080 Ti.
  `install-system.sh` picks `:legacy` from `lspci`. OpenVINO lists the NVIDIA card as a GPU too
  (through `nvidia.icd`; it's plain `GPU` when the Intel runtime is missing), and it can't compile
  the f16 model. `embedsearch.intel_gpu()` picks the device with `vendor=0x8086`. The UHD 770 is
  slow (32 EUs vs the laptop's 96): GPU f16 indexes 4.3 chunks/s with 39 ms queries, the CPU (f32)
  8.9 chunks/s with 14 ms queries, so this box's local config.toml uses `device = "CPU"`. OpenVINO
  can't run the model on the 2080 Ti at all (no Intel-only conversion kernels there, even in f32); a
  CUDA backend (ONNX Runtime) was considered and left out. `MAKEOPTS="-j32 -l32"`; plasma-workspace
  rebuilds in about 6 min.
  Monitors: DP-4 (main, 2560x1440 @ 240 Hz) is on the NVIDIA card (`card1`); DP-1 and HDMI-A-1
  are on the iGPU. KWin composites on the NVIDIA card since 2026-10-12
  (`/etc/environment.d/20-kde-gpu.conf`: `KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0`; it was
  `card0:card1`). With KWin on the iGPU, its blur darkened what's behind a window on DP-4 as if
  gamma were applied twice (a 190 background blurred to about 138): darker glass and a dark fringe
  on the corner arcs (whole-pixel blur region under anti-aliased edges). It was gone with blur
  unloaded, on the iGPU monitors, and everywhere once KWin composited on NVIDIA, so it only hits
  iGPU-rendered frames shown on the NVIDIA card. The preview can't reproduce it (one GPU). With KWin
  on NVIDIA, KRunner renders in software (see the rules above).

## Open items

- **KRunner drag-to-move** was rewritten to follow relative pointer motion and measured on the
  virtual display (exact final position, one even step per frame, clamped at the screen edge). It
  works by hand (rim). The 12 px rim is the only empty spot (the query field spans the full width,
  the results list takes presses), so Meta+drag (KWin's move modifier from kwinrc) works anywhere,
  through an overlay MouseArea that refuses presses without the modifier. KWin passes Meta+click
  to layer-shell windows. Measured on the virtual display; needs a real-hand test after the rebuild.
- **KWin's window shortcuts died during preview work (main box, 2026-10-12):** Alt+F4, Meta+Q and
  Meta+arrows did nothing, while Alt+Tab and KRunner's Meta+Space still worked. kglobalaccel still
  mapped the keys to the right KWin actions, owned its bus name since boot and had no conflicts; a
  relogin fixed it. The user saw the same during earlier desktop dev, so suspect the preview
  sessions (virtual KWin, private bus). Cause unknown; if it recurs, check whether
  `globalShortcutPressed` signals reach `/component/kwin` (dbus-monitor) before relogging.
- **Root-cause fixes for the resize glitches (next up; the KRunner drop-in is a workaround):**
  1. Qt (stretch): fixed by `patches/dev-qt/qtbase/qtbase-wayland.patch` (see the rules above),
     measured clean on the virtual display (software, Mesa GL, scale 1 and 1.25). Qt's dev branch
     still sends the destination early (checked 2026-10-12); no upstream report found. Once the
     patched qtbase is installed, install.sh drops the viewporter workaround from KRunner's drop-in
     (it detects `setViewportDestinationForBuffer` in libQt6WaylandClient); software rendering stays
     until item 2 is fixed.
  2. NVIDIA offset: not located. KWin holds commits until buffers are ready (`src/wayland/transaction.cpp`,
     syncobj and dmabuf fences), yet the old NVIDIA-rendered buffer shows at the new size; a
     Mesa-rendered client was nearly clean (1 in 29), so NVIDIA's egl-wayland in the client is as
     suspect as KWin. Reproduces in `unfold.sh` (preview KWin on NVIDIA by default), so a self-built
     KWin or egl-wayland can be tested there. Time-box it.
  3. Cross-GPU blur darkening: needs the real monitors; skip while KWin composites on NVIDIA.
  Bug report drafts for 2 and 3 were written for the user (not filed; kept outside the repo).
- **Remember password:** the laptop's ksshaskpass passphrase wasn't saved to KWallet yet (tick it
  at login).
