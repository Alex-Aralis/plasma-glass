# plasma-glass: notes for development

Liquid Glass Plasma Styles, semantic KRunner search (EmbeddingGemma 2 on the Intel iGPU via OpenVINO)
and Portage patches for KRunner, notification popups, milou and Qt (Wayland client, Qt Quick). Gentoo, Plasma
6.7.5, Qt 6.11.2, Wayland. User
docs are in README.md; this file covers how to work on it.

## Layout

| Path | What |
|---|---|
| `search/embedsearch.py` | search service: indexer, KRunner D-Bus runner (`local.embedsearch`), CLI. Installed copy: `~/.local/share/embedsearch/` (service `embedsearch.service`) |
| `search/export_model.py` | one-time PyTorch to OpenVINO export with a parity check (run by install.sh in a throwaway venv) |
| `theme/liquid-glass/generate.py` | draws both styles (`liquid-glass`, `liquid-glass-light`) into `~/.local/share/plasma/desktoptheme/` |
| `patches/kde-plasma/{plasma-workspace,milou}/*.patch`, `patches/dev-qt/{qtbase,qtdeclarative}/*.patch` | Portage user patches, one per package |
| `desktop/` | KRunner plugin, systemd and D-Bus files, `plasma-settings.sh` (krunnerrc, kdeglobals, plasmanotifyrc), `krunner-shortcut.sh` (KRunner on Meta+Space, or back on Alt+Space) |
| `tools/patch-dev.sh` | patch workflow: setup, edit, check, refresh, install; `krunner` and `qt` build test copies |
| `tools/check-patches.sh` | patches apply; patched QML loads under qml6 with stubs; patched KRunner C++ syntax-checks |
| `tools/screenprobe/screen.sh` | probes on the real screens (small, never focused, ask first): `fps` measures Qt Quick frame rate and animation speed per screen, `glass` shows the style's glass over a grey square (screenshot or by eye) |
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
  main box), qtbase in about 3 min on the main box. After a Qt rebuild, running apps keep the old
  libraries until they restart (a relogin restarts them all).
- **KRunner C++/QML without an emerge:** `tools/patch-dev.sh krunner` builds just KRunner from the
  edited tree (about 20 s the first time, then seconds) and refreshes a milou QML overlay. Preview:
  `QML_IMPORT_PATH=~/.cache/plasma-glass/dev/qml KRUNNER=$(tools/patch-dev.sh krunner) tools/preview/krunner.sh /tmp/k.png "q"`.
  `tools/preview/fakeinput.c` (built by `common.sh`) sends pointer input to the preview's KWin, and a
  KWin script can print `frameGeometry` of each window, so drags can be measured, not just eyeballed.
- **Qt without an emerge:** `tools/patch-dev.sh setup qtbase qtdeclarative`, edit under
  `~/.cache/plasma-glass/dev/b/qtbase/src/plugins/platforms/wayland/` or
  `.../b/qtdeclarative/src/quick/scenegraph/`, then `tools/patch-dev.sh qt` (about 2 min each the
  first time, then seconds) builds libQt6WaylandClient with the wayland platform and EGL plugins
  (from a qtbase tree) and libQt6Quick (qtdeclarative built as a module against the installed
  qtbase), and prints the environment that loads them into one app:
  `KRUNNER_ENV="$(tools/patch-dev.sh qt)" tools/preview/unfold.sh`. Each build is configured from
  the installed package's USE flags like its ebuild, with Gentoo's own patches, and the tool refuses
  to stage it unless its generated feature headers match the installed ones (one mismatch, AT-SPI
  on, gave `undefined symbol: QSpiAccessibleBridge` at startup). Only the changed libraries are
  swapped in, with the build tree's RUNPATH removed so the installed QtCore and QtGui are used. To
  see which ones a process loaded: `LD_DEBUG=files LD_DEBUG_OUTPUT=/some/prefix` in `KRUNNER_ENV`.
- **Resize glitches:** `tools/preview/unfold.sh` captures ~150 fps while KRunner's results unfold
  and fold and prints `top edge misplaced in N` (old frame shifted) and `N distinct text layouts`
  (old frame stretched; 1 = clean). `KRUNNER=`, `KRUNNER_ENV=` and `KWIN_ENV=` pick the build and
  environment. The stretch comes and goes, so compare several runs. Main box (KWin on NVIDIA),
  2026-10-12: GPU rendering on NVIDIA 22-29 misplaced, 14-16 layouts (the shifts count as layouts
  too) with stock Qt Quick, 0 and 1 in 4 of 4 with the qtdeclarative patch; software rendering
  with stock qtbase 0 misplaced, 1-9 layouts (stretched in 5 of 6 runs), with the qtbase patch 1
  layout in 10 of 10; Mesa GPU rendering
  (`__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`, threaded loop) 1-2
  misplaced and 5 layouts with stock Qt, 1 layout with the qtbase patch. To see which buffer a
  glitched frame came from, run with `KRUNNER_ENV=WAYLAND_DEBUG=client` (the log is the preview's
  `app.log`, times in UTC) and line it up with the frames (`meta.json` has the capture's start
  time, `t0_wall`).
- **Frame rates:** the virtual display runs at 60 Hz, so check refresh-rate behaviour on the real
  screens with `tools/screenprobe/screen.sh fps X,Y [X,Y...]` (positions from `kscreen-doctor -o`;
  `ENV="$(tools/patch-dev.sh qt)"` for a patched Qt, `QSG_RENDER_LOOP=basic` for the GUI-thread
  loop). Main box with KWin on the iGPU, 2026-10-12: stock Qt Quick 62.5 fps on DP-4 (240 Hz) and
  DP-1 (165 Hz); with the qtdeclarative patch 235-239 on DP-4, 165 on DP-1, 60 on HDMI-A-1
  (threaded loop) and 183-194 on DP-4 with the GUI-thread loop; installed, in a full session,
  219-224 on DP-4. The probe's speed figure reads 1.04 for stock and patched Qt alike, so it's
  the probe's own error (not chased). Always say before putting windows on the user's screens.
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
  `zwp_relative_pointer_v1` motion instead, with a virtual pointer in global coordinates, clamped to
  the screens like the real cursor.
- **A layer-shell surface can't change outputs**, so KRunner's drag hops screens by hiding and
  showing itself on the screen the virtual pointer entered (`View::moveToScreen`; `changingScreen`
  stops RunCommand.qml from clearing the query and stops focus loss from hiding it). Two traps: the
  press in the old surface ends in Qt's view, with a cancel to the MouseArea and a release Qt makes up
  itself, both arriving after the hop; so after a hop only the compositor's button events on a
  `wl_pointer` of KRunner's own (`ButtonWatcher`) end the drag. Relative motion keeps coming through
  the hop. `tools/preview/drag.sh` drags across two virtual screens (`OUTPUTS=2` for the preview's
  KWin) and logs KRunner's geometry and output from a KWin script.
- **Layer-shell margins only apply on a commit.** layer-shell-qt's `setMargins` just sends
  `set_margin`; `requestUpdate()` doesn't render an unchanged scene, so nothing commits. Use
  `QQuickWindow::update()`.
- **Qt Quick's GUI-thread render loop drew the frame after a resize at the old size** (fixed by
  `qtdeclarative-quick.patch`): `QSGGuiThreadRenderLoop::renderWindow` took the surface size before
  `polishItems()`, but a window sized to its content (KRunner, Plasma dialogs) resizes during
  polish, when layouts compute implicit sizes, and on Wayland the EGL surface takes the new size at
  once. The old-size frame landed in the new-size buffer bottom-aligned (GL's origin is
  bottom-left): on each step of KRunner's unfold its old frame showed pushed down by the growth, or
  up and clipped when shrinking. Qt uses that loop whenever the EGL vendor is NVIDIA on a desktop
  (`QWaylandEglClientBufferIntegration`, QTBUG-95817; `QSG_INFO=1` prints the loop), so it showed
  with NVIDIA client rendering only, and looked like a KWin bug: the first commit at each new size
  carried the shifted content (WAYLAND_DEBUG), so KWin showed what it got. Mesa clients get the
  threaded loop, which polishes before it takes the size (1-2 glitches remain there: a resize on
  the GUI thread after the sync). Not egl-wayland: v1 and v2 behaved the same.
- **Qt Quick's threaded loop also drew an old frame into a new buffer, at high refresh rates** (fixed in
  `qtbase-wayland.patch`): the main thread polishes the next frame, and resizes the window then
  (`QWaylandEglWindow::ensureSize`, `wl_egl_window_resize`), while the render thread is still drawing
  the previous one; Mesa allocates that frame's buffer lazily, so it could get the new size and the
  frame showed pushed down for one frame. The user saw it typing "fff" then Backspace while KRunner
  was still unfolding, on the 240 Hz screen; at 60 Hz it hardly happens. Now a resize that comes
  while a frame is in flight (between `QWaylandGLContext::beginFrame` and `endFrame`) waits for that
  frame's swap. Reproduce with `REFRESH=240000` (the preview KWin gets a 240 Hz custom mode through
  kscreen-doctor), `KWIN_ENV`/`KRUNNER_ENV` pointing EGL at Mesa, and `KEYS="33 33 33 14"` (typed
  with fakeinput) in `unfold.sh`: installed Qt 7 shifted frames in 4 of 10 runs, the fix 0 in 10.
  Installed on the main box 2026-10-12.
  Left over: forcing `QSG_RENDER_LOOP=basic` on Mesa gives one frame shifted up about 6 px in most
  such runs (the buffer was allocated before polish resized the window); stock and patched alike,
  and no real setup uses that pairing (Mesa gets the threaded loop, NVIDIA the GUI-thread one).
- **Qt Quick animated at 60 fps on faster screens** (fixed by `qtdeclarative-quick.patch` too). The
  threaded loop's animation driver steps one frame of the *primary screen* per frame, and Qt's
  primary on Wayland is simply the first output (HDMI-A-1, 60 Hz; QtWayland ignores KDE's output
  order). On DP-4 frames came every 4-5 ms, "less than half" the expected 16.7, so Qt decided vsync
  was broken and animated from a 16 ms timer (`QSG_INFO=1`: "determined to have broken vsync
  throttling"). The GUI-thread loop (NVIDIA clients) uses QtCore's animation timer, 16 ms by
  default. The patch makes each window track its screen's refresh rate: the threaded loop's driver
  and fallback timer follow the fastest screen with an exposed window, its render-thread animator
  drivers their window's screen, and the GUI-thread loop sets QtCore's timer interval the same way
  (back to the defaults when nothing is shown). `QSG_USE_SIMPLE_ANIMATION_DRIVER=1` was the stopgap.
- **CPU rendering (`QT_QUICK_BACKEND=software`) avoided that but stretched the old frame** in 3 of 4
  runs (text flicker), until the qtbase patch (below); also setting
  `QT_WAYLAND_DISABLED_INTERFACES=wp_viewporter,wp_fractional_scale_manager_v1` was clean (fractional
  scales would render at the next whole scale). install.sh puts these in a `plasma-krunner.service`
  drop-in when KWin's GL vendor is NVIDIA and the Qt patches aren't installed (software only once the
  qtbase one is; none with both). Check animations by text positions too, not just edges: a stretch
  keeps the top edge in place. Found by capturing frames from the preview KWin at ~150 fps: start it
  with `KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1` and call `org.kde.KWin.ScreenShot2.CaptureActiveScreen`
  in a loop (dbus-fast: the `h` argument is the index into `unix_fds`; raw BGRA, format 6).
- **KRunner's busy feedback is a ripple shader** (`krunner/qml/busyripple.frag`, `busyRipple` in
  RunCommand.qml, built into the QML module by `qt6_add_shaders`). While busy, every 1.2 s, knocks on
  the left rim beside the query (and near the bottom while results show) each send one wave across the
  glass. A knock flexes its side (most at the knock, none at the corners; a 1 px stretch moves at once,
  then the flex slows to the waves' speed over 30 px, so the front is rounded, not a cone); waves fade
  with time and as they head into a rim. Liquid Glass: light comes in at the rim (generate.py RIM) and
  lets out where a slope faces an edge, and the content refracts: the ShaderEffect draws it from a
  ShaderEffectSource of the layout, hidden while the ripple runs (the dividers aren't in it, so they
  don't bend). Liquid Glass Light: a flat foil sheen of fixed-colour shards, no refraction (colours that
  moved with the wave's tilt flickered). `KRUNNER_BUSY_DEMO=1` keeps it running, to look at it (also in
  `tools/preview/krunner.sh`). dFdx/dFdy are undefined after a per-pixel early exit, so a wave's
  direction is computed, not differentiated (the unit vector from where it left the side). Tried and
  dropped: slowing waves near the rim (a kink where it starts; tails along the rims when it piled up),
  shading on light glass (a white smear, then heavy relief), glitter specks. Designed in a lab copy of
  KRunner (a `PlasmaCore.Window` with the same layout), recorded on the virtual display.
  It's drawn in passes, because KRunner shares the iGPU with KWin: `busywaves.frag` works out the
  waves' slope and height at half resolution (an RGBA16F ShaderEffectSource), `busyfoil.frag` draws the
  foil's shards once into a repeating tile, and `busyripple.frag` draws the rest at full resolution.
  All in one full-resolution shader it cost 1.85 ms of GPU per frame (a 744x640 window; the content
  alone is 0.27 ms), and in a real session KWin then missed DP-4 refreshes (208 fps, later about 60);
  in passes it's 0.55 ms. A process's GPU time is in `/proc/PID/fdinfo` (`drm-engine-render`, once
  per `drm-client-id`; KWin's isn't readable as a user). Frame pacing is in a `WAYLAND_DEBUG=client`
  log: the time from `wl_surface.frame` to its `wl_callback.done` is KWin's, from the done to the
  next commit the client's.
- **Without shaders (software rendering) the busy pulse is a gradient, not a mask.** The band of
  light that stands in for the ripple is the gradient of a rounded Rectangle over the glass (stops
  moved by a 0..1 progress), so it keeps to the corners at every size. A MultiEffect mask (the
  style's frame SVG, then a rounded Rectangle) let it show past the corners while the results folded
  away. Animate a 0..1 property, not `x` with `from`/`to` from sizes: those are fixed when the
  animation starts (the first try started at width 0 and slid from 0 to 0). The overlay stays
  visible until the band is off the glass, so a sweep under way when the search ends finishes
  (`alwaysRunToEnd` alone doesn't, `running` drops at once).
- **An item that takes a press doesn't hide it from pointer handlers underneath.** Qt Quick goes on
  delivering it to the handlers below (handlers only), and they keep passive grabs. KRunner's Meta+drag
  was an overlay MouseArea at first: started over a result, milou's `DragHandler` took the result's
  grab as soon as the window changed screens (hiding it ends the MouseArea's grab) and began a real
  drag and drop of the result (`start_drag` in WAYLAND_DEBUG) while the window was being dragged. Now
  `View::event` takes modifier presses and everything up to the release before Qt Quick sees them. That
  has to be `event()`: QQuickWindow calls the `mouse*Event()` overrides first, but delivers anyway
  unless the event came in unaccepted, and it never does.
- **`Layout.maximumHeight` alone animates growing, not shrinking.** The layout takes the smaller of
  an item's own height and its maximum, so when KRunner's results went from 15 rows to 1, the list's
  height fell at once and the window snapped from 827 to 353 px in two frames while the animated
  maximum was still high (seen after holding a key down, as the last query's results arrive). The
  results area sets `Layout.preferredHeight` to the animated height too. `unfold.sh` with
  `KEYS="33:1500" SECONDS_CAPTURED=5 BOTTOMS=1` holds F for 1.5 s and prints the bottom edge of every
  frame.
- **KRunner's lists run into the window's bottom padding** when they don't fit, so rows are cut at
  the glass's edge, not 12 px above it: the ScrollView reaches into the padding
  (`Layout.bottomMargin: -bottomPadding`, the same added to its preferred and maximum heights, so the
  layout's height doesn't change), its `bottomPadding` keeps the ListView itself at the old size, and
  the ListView draws rows on into the padding with `displayMarginEnd` (rows there aren't culled) and
  `clip` off, set in `Component.onCompleted` because Plasma's ScrollView forces `clip: true` on its
  list with a Binding that writes once at completion. ListView's own scrolling then works as before.
  The first try made the ListView taller with `bottomMargin` and kept the current row clear with
  `highlightRangeMode: ApplyRange`, but with a highlight range `QQuickItemView::trackedPositionChanged`
  ignores section headers (only the no-range path adds `sectionSize`), so when results arrived in
  batches and row 0 was made current again, its header hid under the divider until the unfold ended.
  Reproduce: `HEIGHT=560 SCALE=1.1 KEYS="33 - 103 - 108 -" tools/preview/unfold.sh` (Up wraps to the
  last row, Down back to row 0) and look at `shots/app.png`. A ScrollView is a Pane, which takes every
  press inside it, so the bottom rim doesn't drag the window while results show (fine: the user
  only drags with Meta).
- **KRunner's indexing bar comes from the search service over D-Bus.** embedsearch exports
  `local.embedsearch.Indexer` at `/indexer` with a `Progress` property (share of files done while
  `update_index` runs, from the embedding batches, at most 4 updates a second; -1 otherwise), and
  KRunner's View follows its PropertiesChanged signal (`indexingProgress`; -1 too when the service
  goes away). Its `Index()` method (the "Index" launcher, `desktop/embedsearch-index.desktop`) wakes
  the reindex loop at once and sends a notification when that run ends. Preview: `INDEXING="DELAY DURATION"` in krunner.sh or unfold.sh starts
  `tools/preview/fake-indexer.py` in the preview session (it owns `local.embedsearch`, so semantic
  matches fail there with an UnknownMethod error). The bar's slide measured with
  `INDEXING="4.5 2" KEYS="-" SECONDS_CAPTURED=4.5 BOTTOMS=1 tools/preview/unfold.sh`.
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
- **Global shortcuts belong to kglobalaccel while a session runs** (inside KWin since Plasma 6, no
  D-Bus activation): it rewrites `kglobalshortcutsrc` from memory, so set keys over D-Bus
  (`setForeignShortcut`, Qt key codes) and only edit the file when it isn't on the bus.
  `isGlobalShortcutAvailable` says false even when the key is the asking component's own; ask
  `action(key)` who has it instead. `shortcut()` returns the keys sorted by code, not in order.
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
  rebuilds in about 6 min. GCC 16 segfaulted once (2026-10-12, an internal compiler error on a
  generated qmltyperegistrations file that had compiled minutes before); the retry built fine. A
  second one came the same evening (23:58, a segfault in `mangle_decl` on
  `kcms/kfontinst/dbus/FontInst.cpp`, untouched by the patches, which had built three times that day).
  Microcode is 0x137 (Intel's Raptor Lake instability fixes) and no machine checks were logged; if
  random compiler crashes come back, suspect the CPU (13th/14th-gen Vmin degradation).
  Monitors: DP-4 (main, 2560x1440 @ 240 Hz) is on the NVIDIA card (`card1`); DP-1 and HDMI-A-1
  are on the iGPU. KWin composites on the NVIDIA card since 2026-10-13 (the
  `plasma-kwin_wayland.service` drop-in `gpu.conf` and `/etc/environment.d/20-kde-gpu.conf`, both
  `KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0`). On the iGPU (2026-10-12 to 10-13, to watch for
  bug 3), KWin copied every DP-4 frame across to the NVIDIA card and showed a frame late for one in
  five at 240 Hz, while DP-1 ran at its full 165. On NVIDIA, KRunner's busy ripple (KRunner renders
  there too) ran at 228 fps on DP-4 with one frame in ten late, all KWin's (its frame callbacks;
  KRunner answered each in 0.06 ms), and at the full 165 on DP-1. Changing environment.d needs a
  reboot: the systemd user manager reads it only when it starts and outlives a relog while anything
  keeps the session open (tmux, the root terminal), and even `systemctl --user set-environment` was
  undone at the next login (the session bus, up since boot, still had the old value and Plasma's
  startup pushes it back). Without a reboot, set it on KWin's unit instead: a drop-in in
  `~/.config/systemd/user/plasma-kwin_wayland.service.d/` with `Environment=KWIN_DRM_DEVICES=...`,
  then `systemctl --user daemon-reload` and relog; check with the GL vendor in
  `qdbus6 org.kde.KWin /KWin supportInformation`. With KWin on the iGPU, its blur darkened what's
  behind a window on DP-4 as if gamma were applied twice (a 190 background blurred to about 138):
  darker glass and a dark fringe on the corner arcs (whole-pixel blur region under anti-aliased
  edges). It was gone with blur unloaded, on the iGPU monitors, and everywhere once KWin composited
  on NVIDIA, so it only hits iGPU-rendered frames shown on the NVIDIA card. The preview can't
  reproduce it (one GPU). Both Qt patches are installed here (2026-10-12), so KRunner renders on the
  GPU with no drop-in.

## Open items

- **KRunner drag-to-move** was rewritten to follow relative pointer motion and measured on the
  virtual display (exact final position, one even step per frame, clamped at the screen edge). It
  works by hand (rim). The 12 px rim is the only empty spot (the query field spans the full width,
  the results list takes presses), so Meta+drag (KWin's move modifier from kwinrc) works anywhere;
  `View::event` takes those presses before Qt Quick (see the rules). KWin passes Meta+click to
  layer-shell windows. Measured on the virtual display; needs a real-hand test after the rebuild.
  Dragging onto another monitor (2026-10-12): measured on two virtual screens (lands at the exact
  spot, keeps the query, results and keyboard) and confirmed by hand on the main box, including
  reopening on the screen it was last dragged to (`FloatingScreen`, the output name; the active
  screen when that one isn't connected; `drag.sh` with `REOPEN=1` checks this).
- **KWin's window shortcuts died during preview work (main box, 2026-10-12):** Alt+F4, Meta+Q and
  Meta+arrows did nothing, while Alt+Tab and KRunner's Meta+Space still worked. kglobalaccel still
  mapped the keys to the right KWin actions, owned its bus name since boot and had no conflicts; a
  relogin fixed it. The user saw the same during earlier desktop dev, so suspect the preview
  sessions (virtual KWin, private bus). Cause unknown; if it recurs, check whether
  `globalShortcutPressed` signals reach `/component/kwin` (dbus-monitor) before relogging.
- **Root-cause fixes for the resize glitches (the KRunner drop-in is the workaround until they're installed):**
  1. Qt (stretch): fixed by `patches/dev-qt/qtbase/qtbase-wayland.patch` (see the rules above),
     measured clean on the virtual display (software, Mesa GL, scale 1 and 1.25). Qt's dev branch
     still sends the destination early (checked 2026-10-12); no upstream report found. Once the
     patched qtbase is installed (emerged 2026-10-12), install.sh drops the viewporter part of
     KRunner's drop-in.
  2. NVIDIA offset: Qt Quick, not KWin; fixed by `patches/dev-qt/qtdeclarative/qtdeclarative-quick.patch`
     (see the rules above), measured clean on the virtual display. Installed 2026-10-12 (qtdeclarative
     emerge about 10 min); install.sh then removed KRunner's drop-in, and the installed Qt measured
     0 misplaced and 1 layout in 3 of 3 with GPU rendering. Upstream qtdeclarative still takes
     the size before polishing (6.11.2; check dev before reporting). The KWin bug report draft for
     this was wrong (KWin showed what it got); the user was told not to file it.
  3. Cross-GPU blur darkening: not reproducible on 2026-10-12 after a reboot, with KWin back on the
     iGPU: a probe (now `tools/screenprobe/screen.sh glass`: a 190 grey square with an empty
     `PlasmaCore.Window` on it, the style's glass and blur, placed by a KWin script) measured the glass at
     129 (dark) and 225 (light) on DP-4 and DP-1 alike, the same as with KWin on NVIDIA, and the
     user saw no darker glass or corner fringe on DP-4. It was first seen in a KWin session up since
     10-09 (relogged 10-12 18:27), so it may build up over a long session or follow a monitor
     event (DPMS, hotplug), or it depended on something changed since (the style's corner glow was
     redrawn during that investigation). Screenshots are re-rendered by KWin, so a darkening in the
     copy to the NVIDIA card would only show to the eye. A KWin bug report draft was written for the
     user earlier (not filed; kept outside the repo); don't file it unless this comes back. KWin
     composites on the NVIDIA card again since 2026-10-13, so this watch has ended.
- **Remember password:** the laptop's ksshaskpass passphrase wasn't saved to KWallet yet (tick it
  at login).
