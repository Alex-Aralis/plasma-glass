# plasma-glass: notes for development

Liquid Glass Plasma Styles, semantic KRunner search (EmbeddingGemma 2 on the Intel iGPU via OpenVINO)
and Portage patches for KRunner, notification popups, milou, KWin (frame pacing, a crash on exit, the dark style's bevel) and Qt (Wayland client, Qt Quick). Gentoo, Plasma
6.7.5, Qt 6.11.2, Wayland. User
docs are in README.md; this file covers how to work on it.

## Layout

| Path | What |
|---|---|
| `search/embedsearch.py` | search service: indexer, KRunner D-Bus runner (`local.embedsearch`), CLI. Installed copy: `~/.local/share/embedsearch/` (service `embedsearch.service`) |
| `search/export_model.py` | one-time PyTorch to OpenVINO export with a parity check (run by install.sh in a throwaway venv) |
| `theme/liquid-glass/generate.py` | draws both styles (`liquid-glass`, `liquid-glass-light`) into `~/.local/share/plasma/desktoptheme/` |
| `patches/kde-plasma/{plasma-workspace,milou,kwin}/*.patch`, `patches/dev-qt/{qtbase,qtdeclarative}/*.patch` | Portage user patches, one per package |
| `desktop/` | KRunner plugin, systemd and D-Bus files, `plasma-settings.sh` (krunnerrc, kdeglobals, plasmanotifyrc), `krunner-shortcut.sh` (KRunner on Meta+Space, or back on Alt+Space), `plasma-glass-tune.qml` (Liquid Glass Tuning: the ripple and the dark glass, live) |
| `tools/patch-dev.sh` | patch workflow: setup, edit, check, refresh, install; `krunner` and `qt` build test copies, `kwin` compiles the edited KWin files |
| `tools/check-patches.sh` | patches apply; patched QML loads under qml6 with stubs; patched KRunner C++ syntax-checks |
| `tools/screenprobe/screen.sh` | probes on the real screens (small, never focused, ask first): `fps` measures Qt Quick frame rate and animation speed per screen, `glass` shows the style's glass over a grey square (screenshot or by eye) |
| `tools/preview/` | screenshots on a virtual KWin display: `krunner.sh`, `dialog.sh`, `popup.sh` (a real plasmashell tray popup), `elements.sh`; `unfold.sh` measures KRunner's resize animation frame by frame (`frames.py`); `record.sh` records KRunner into a video (demos); `fakeinput.c` for pointer input |
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
  main box), qtbase in about 3 min and kwin in about 3½ min on the main box. After a Qt rebuild, running
  apps keep the old libraries until they restart (a relogin restarts them all); a new KWin runs from
  the next login. `tools/patch-dev.sh kwin` compiles the edited KWin files first (20 s the first time).
- **KRunner C++/QML without an emerge:** `tools/patch-dev.sh krunner` builds just KRunner from the
  edited tree (about 20 s the first time, then seconds) and refreshes a milou QML overlay. Preview:
  `QML_IMPORT_PATH=~/.cache/plasma-glass/dev/qml KRUNNER=$(tools/patch-dev.sh krunner) tools/preview/krunner.sh /tmp/k.png "q"`.
  `tools/preview/fakeinput.c` (built by `common.sh`) sends pointer input to the preview's KWin, and a
  KWin script can print `frameGeometry` of each window, so drags can be measured, not just eyeballed.
- **Demos:** `tools/preview/record.sh OUT.mp4 "query"` (same `QML_IMPORT_PATH` and `KRUNNER` as above)
  records KRunner's window with the busy feedback running (`BUSY=0` for none; `SECONDS_CAPTURED`,
  default 6) at 60 fps, through KWin's `CaptureArea` on a 120 Hz virtual screen, and keeps a lossless
  `OUT.mkv`; `QUERY2` follows `QUERY2_AT` s in, so a query of `""` records the results unfolding. For a
  side-by-side the knocks have to line up: both recordings start 5.5 s after KRunner,
  and two of them came out within a frame of each other in the 1.2 s cycle (check where a knock's
  light peaks beside the query; `ffmpeg -i a.mkv -i b.mkv -filter_complex vstack`).
- **KWin in the preview:** after `tools/patch-dev.sh kwin`, `ninja -C ~/.cache/plasma-glass/dev/kwin/build
  kwin_wayland` links a whole KWin (2¼ min the first time on the main box, then about 12 s; effects
  like blur are built in), and `KWIN_WAYLAND=~/.cache/plasma-glass/dev/kwin/build/bin/kwin_wayland` runs
  it as the preview's compositor instead of the installed one (`KWIN_ENV` for its environment). KWin
  only redraws what changes, so to see or measure the blur behind KRunner over time, scroll the
  wallpaper: `WALLPAPER_PAN=40` (px/s; with record.sh, since screenshots crop to what changed). A still
  scene made KWin's GPU time read 0.05 ms a frame instead of 2.
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
  RunCommand.qml, built into the QML module by `qt6_add_shaders`). While busy, every 1.2 s, a knock on
  the left rim sends a wave across the glass: beside the query while the window shows only that, and once
  results show `knockAlong` (a third) of the way down the glass, never above the query (2026-10-14: the
  user asked to keep the closed spot and try a third and the middle when open; checked by logging each
  knock's spot, 31 of 62 px closed and 115 of 346 open). A second knock near the bottom while results
  showed was dropped, 2026-10-13: one is enough. A knock flexes its side (most at the knock,
  none at the corners; a 1 px stretch moves at once, then the flex slows to the waves' speed over 30 px,
  so the front is rounded, not a cone). Waves run at 120 px/s, 21 px half-width when fresh and widening
  8 px/s (2026-10-14: the user asked to slow them to 2/3 and widen them by as much; from 180 px/s and
  14 px, so at each point across they're now 1.5x as wide). With knocks still 1.2 s apart their crests
  are 144 px apart, not 216, and the wider waves crowd into each other (the sheen on light glass nearly
  merges); a knock every 1.8 s keeps them as far apart as before, recorded for the user to compare.
  Waves fade with time, by e in 36 s, so a crest keeps 84% of itself across the 744 px glass (2026-10-14,
  "it's fading too fast": 18 s and 70% before), and a knock's wave lasts 9.5 s, long enough for its
  ringing to cross too, and short enough that no more than 8 live at once (as many as the shaders take);
  heading into a rim they fade only in its last few px
  (half is left 3 px from it), so they run on across KWin's bevel (2026-10-14: the user wanted them to
  travel farther and the damping backed off the bevel's edges; before, by e in 5 s and gone after 4.8, a
  crest kept a third of itself across, and the rim faded them from 15 px in, over the whole bevel). Each
  wave is a crest with a ringing train behind
  it (`profile()`, the same in busywaves.frag and KWin's ripple.frag): a smooth rise ahead, then ripples
  that get shorter and fade, -0.42, +0.18, -0.09, +0.05 of the crest, a damped Airy function's tail, as
  an impulse leaves it in a dispersive medium (2026-10-14: "trailing reverb closer to a real impulse";
  before, a single e^-x² bump). Its slope is scaled by its steepest, 0.991 just behind the crest (the
  front's is 0.858), and a knock's wave reaches 9 half-widths behind
  its crest. On dark glass KRunner draws nothing of it (2026-10-14): first its side lighting went (light
  that comes in at the rim, generate.py RIM, let out where a wave's slope faces an edge), then the
  content's refraction and colour split (2 px x lean² uphill, 1 px x lean each way); the user wants the
  waves to show only by what KWin bends behind the glass, and the text left alone. So busyRipple only
  shows on Liquid Glass Light, and on dark glass only the knocks run (a FrameAnimation while `rippling`):
  each goes to KWin over D-Bus (`View::knock`, org.kde.KWin.LiquidGlass.Knock, with the wave's speed,
  bump, spread, damping, life and steep), born on the monotonic clock both run the ripple on
  (`View::monotonicTime()`; the ripple's clock used to sum frame times, capped at 0.1 s, which a stall
  would have put behind KWin's). KRunner's own GPU time while busy went from 0.78 to 0.30 ms a frame
  (preview, UHD 770 through Mesa, 744x346 at scale 1.1). Liquid Glass Light used to get a flat foil
  sheen of fixed-colour shards over the crests, drawn by busyRipple over the glass (no refraction:
  colours that moved with the wave's tilt flickered; it draws the content too, over the sheen, from a
  ShaderEffectSource of the layout hidden while it runs, without the dividers). Since 2026-10-14 the
  waves go beneath the frost there too ("put the wave beneath the frosting"), drawn by KWin (below). The
  sheen over the glass came back as a place for the foil, `[Light] layer` top or both (the user asked for
  a setting to put the diffraction back on top), as bright as 0.3 x `[Light] diffraction` (1.2 gives the
  0.35 it had), with `[Light] etch` and `saturation`, KWin's foil skipped for top; busyFoil only renders
  its tile while the sheen is on. Its waves (busywaves.frag) follow KWin's ripple.frag, the effects
  below included, so the shards on top lie over the waves beneath.
  `KRUNNER_BUSY_DEMO=1` keeps it running, to look at it (also in `tools/preview/krunner.sh`, and
  `tools/preview/record.sh` records it). dFdx/dFdy are undefined after a per-pixel early exit, so a
  wave's direction is computed, not differentiated (the unit vector from where it left the side). Tried and
  dropped: slowing waves near the rim (a kink where it starts; tails along the rims when it piled up),
  shading on light glass (a white smear, then heavy relief), glitter specks, the side lighting on dark
  glass (above). Designed in a lab copy of
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
- **KWin sent clients their messages only when its event loop was about to sleep** (`Display::flush`
  on `aboutToBlock`), so a frame callback queued at the end of one screen's composite also waited for
  any composite due next on another screen. On the main box that was long: with KWin on the NVIDIA card,
  every frame for the iGPU's screens was copied there through the CPU (`EglGbmLayerSurface::importWithCpu`,
  a whole-frame `glReadnPixels` on the main thread; "chose cpu import" in the journal with
  `QT_LOGGING_RULES=kwin_wayland_drm.debug=true` on KWin's unit), 2.6 ms per DP-1 frame. KRunner's
  ripple on DP-4 got its callbacks that much later, and 20.6% of its frames missed DP-4's next composite
  while DP-1 animated (1.6% with DP-1 idle). `kwin-fixes.patch` flushes clients at the end of each
  composite (4.0% then), and lets the render GPU make those copies when the display GPU can't (a
  `RenderGpuCopy` import mode, tried after the display GPU's copy and before the CPU's; "chose render gpu
  copy" in the journal, `KWIN_DRM_NO_RENDER_GPU_COPY=1` turns it off). KWin's Vulkan copy
  (`MultiGpuSwapchain::copyWithVulkan`: changed areas only, fences, no CPU wait) only ever ran on the
  screen's own GPU, and the iGPU can't read NVIDIA's buffers. NVIDIA's OpenGL (driver 615) takes linear
  dma-bufs as "external only" (sampling, no framebuffer), but its Vulkan imports a linear buffer the
  iGPU allocated and writes into it: a test program on KWin's exact path (an NVIDIA-tiled source,
  KWin's barriers and blit, the render's sync fd imported as a semaphore) got 60 of 60 copies right,
  3.7 ms of GPU time per 2560x1440 frame. The card doesn't snoop the CPU cache, though: the kernel
  zeroes a new buffer's pages through it, the card's writes went around those lines, and once those
  were written back (at the latest when i915 flushes the buffer to show it) the zeros covered the copy.
  The cursor on DP-1 then showed with horizontal strips missing, all of it with the machine idle (the
  cache kept the lines), and right again after a shape change (a copy into an older buffer). So new
  copy targets are clflushed through their dma-buf before the card writes (`flushCpuCache` in
  vulkan_swapchain.cpp); i915's set-domain and set-caching ioctls don't flush them on this LLC
  platform. Off screen: allocate the iGPU buffer after creating the NVIDIA Vulkan device and read it
  back through a write-combined mapping, and nearly every row is lost; allocated before (the device
  setup evicts the lines), or flushed, none. Measured 2026-10-13 with DP-1 animating: KRunner 236.5 fps
  with 1.0% late (228 and 10% before), 0.8% missed, a new DP-4 frame at every refresh; with DP-1 and
  HDMI-A-1 both animating, DP-4 went from 1.4-8.7% of refreshes without a frame to 0.0-0.1%. To
  measure: `KWIN_LOG_PERFORMANCE_DATA=1` on KWin's unit makes it write `~/kwin perf statistics
  <output>.csv` per screen (truncated when KWin starts), on the monotonic clock of the clients' frame
  callbacks, so a client's `WAYLAND_DEBUG` log lines up with KWin's frames.
- **KWin crashed at every logout and shutdown** (SIGSEGV, 47 core dumps by 2026-10-13, preview KWins
  included), in a QML script's `Component.onDestruction`: Remember Window Positions 7.0.0 (rxappdev, in
  `~/.local/share/kwin/scripts`) saves the stacking order there. `Workspace::~Workspace()` resets
  `_self` and only then deletes its children, Scripting among them, whose QML engine destroys the
  scripts' objects; the script's `Workspace.stackingOrder` then went to `workspace()->stackingOrder()`
  on a null `workspace()` (`WorkspaceWrapper::stackingOrder`, workspace_wrapper.cpp:340). So the
  script's final save never ran either. `kwin-fixes.patch` unloads the scripts at the top of
  `~Workspace()` (`Scripting::unloadScripts()`), while the workspace still works; Scripting itself
  still goes last, since the window switcher, the outline, the OSD and effects share its QML engine.
  Reproduce without logging out: a virtual KWin (`--virtual`, its own socket, private bus and
  `XDG_CONFIG_HOME` with a copy of kwinrc, `~/.local/share` in `XDG_DATA_DIRS` for the script) under
  gdb, two qml6 windows opened and closed, then SIGTERM, as at logout. Stock, it crashed every time;
  fixed, it exits with 15 and the script logs its final save (`debugLogs=true` in its kwinrc group).
  KWin's cores are root-only (kwin_wayland has a file capability), so use a debug build of the dev
  tree (`ninja -C ~/.cache/plasma-glass/dev/kwin/build kwin_wayland`, RelWithDebInfo) for symbols.
- **The dark Liquid Glass bevel is drawn by KWin's blur** (`kwin-fixes.patch`: the bevel pass in
  `plugins/blur/blur.cpp`, `shaders/onscreen_bevel.frag`), since only KWin has what's behind the glass;
  KRunner's shaders only see its own content. The glass is the blur region's bounding box, with a 26 px
  radius (generate.py R) at each corner the frame's mask leaves out of the region; a shape with no
  corner left out (a docked panel) gets no bevel, nor does a window with a title bar (it has KWin's own
  border radius). Within 24 px of the edge the glass rounds off like a quarter circle (tilt 1 at the
  edge, 0 where it turns flat): what's behind is seen from 9 px x tilt² further in, the background
  before the blur (the blur's first texture) shows through more towards the edge (x tilt), and red is
  taken from 2 px x tilt further out, blue as far in. That's the per-colour sampling along the normal
  that [liquidglass](https://github.com/ybouane/liquidglass) uses, whose bevel is a half circle. On the
  blur alone the colour split doesn't show; the sharp background makes it visible. A refraction linear
  in the tilt (16 px over 24) magnified a thin strip 3x evenly and smeared glyphs into colour streaks;
  with tilt² it starts smoothly, and it folds over if the refraction passes half the width. While
  plasmarc's `[Theme] name` is `liquid-glass`, or `liquid-glass-light` (below), watched with
  KDirWatch since the style's settings page doesn't notify; tested by rewriting the preview's plasmarc
  mid-recording. `KWIN_LIQUID_GLASS_BEVEL=width,refraction,dispersion,sharpness` (24,9,2,1) in KWin's
  environment overrides it, to tune without a rebuild. A shader that fails to compile drops only the
  bevel. The glass is frosted lightly all over: blur strength 2 of BlurStrength's 1-15 (one halving,
  offset 2), never above the user's own; KWin's default is 15, the heaviest. With that in the middle and
  a clear bevel, the middle didn't match the bevel (the user, 2026-10-14): a clear frame around frosted
  plastic; then 4, and 3, were still a bit much. liquidglass frosts lightly everywhere too (blurAmount
  0.25-0.4 on its demo page) and its bevel bends that same blur, with 15% of the sharp background at the
  rim. Here the bevel stays sharp at the rim (the look the user approved) and the middle is frosted
  lightly enough to show shapes, so one fades into the other. `KWIN_LIQUID_GLASS_FROST=strength`
  overrides it. KRunner's busy ripple leans the glass too: KWin keeps the knocks KRunner sends
  (`Knock()`, matched to the window by the caller's PID), works the waves out again at half size
  (`shaders/ripple.frag`, a copy of busywaves.frag, in window coordinates), and adds their downhill slope
  over the steepest to the bevel's lean, so the bend and the colours' parting follow from one lean per
  pixel; a fresh wave's steepest slope leans as far as the bevel's edge. A wave parts the colours a little
  more than the bevel, 3 px each way where it leans fully against the bevel's 2 (2026-10-14: "a tiny bit
  more aberration on the wave"): the split adds the waves' own lean, up to 1, times the difference
  (`KWIN_LIQUID_GLASS_RIPPLE=scale[,dispersion]`, 1,3; scale 0 for no waves). How clear the glass is
  follows the bevel's lean, and under a wave its lean or its height (up or down), whichever is more: by
  the lean alone the glass frosted over again at each crest, which is flat (the user didn't like it).
  KWin keeps repainting while knocks live, whatever KRunner draws. The colours part only in the sharp
  samples: on the frost it doesn't show, and the blur's 8 samples three times over cost twice as much
  once the waves spread the per-pixel path over most of the window. In the preview (UHD 770 through
  Mesa, KRunner busy at 744x346, scale 1) KWin's GPU time is 1.12-1.20 ms a frame with the bevel and
  frost 2 and 1.96-1.98 with the slow, wide waves, eight knocks' at once (1.78-1.80 with a knock every
  1.8 s; at 180 px/s and 14 px 1.66-1.69, six at once, and 1.56-1.59 while they lasted 4.8 s, four at
  once, all once that many lived; with single waves 1.49-1.52; at frost 3, 1.25 and 1.57-1.62; with all
  27 samples, 1.40 and 2.12-2.15); with the wallpaper scrolling and
  KRunner idle it went from 2.04 (no bevel, strength 15) to 2.25-2.28 (bevel, strength 4). Over a smooth
  wallpaper (Next) it hardly shows: tuned on ColorfulCups and a scrolling image of code.
- **The ripple and the dark glass are tunable live** (2026-10-14, the user asked for a settings menu to
  fiddle with damping, aberration, strike location, speed, amplitude and width).
  `~/.config/plasma-glassrc` holds them: `[Ripple]` is KRunner's (`View::liquidGlass`, numbers as
  numbers, read again on every change through KDirWatch; RunCommand.qml falls back to its defaults key
  by key), and each knock carries its wave's settings to KWin, amplitude (`lean`), colour split
  (`dispersion`), ringing (`ring`) with the profile's steepest slope for it (`norm`, worked out in
  `steepest()`: 0.991 at the default 1.7) and edge fade (`edge`) included. So waves under way keep
  theirs when a setting changes, here and in KWin, which takes the latest knock's amplitude, split and
  edge fade for the whole glass and each knock's ringing (`shapes[i].zw`). Two more came the same day:
  how far in from the rim the edge fade sits (`standoff`, 0; global like the edge fade) and how much of
  the side a knock strikes at once (`strike`, 1 px; per knock in `shapes[i].y`, half of it: the stretch
  that moves at once, so the wave leaves flat across it). The flex's exponent used to go in that slot;
  the shaders work it out from the knock's place on its side now. `[Glass]` is KWin's (frost,
  bevel), read again on every change too; `KWIN_LIQUID_GLASS_*` still win over the file, so the
  preview's before/after recordings work as before. The ringing culls at 1.4 + 4.6 x its fade
  half-widths behind the crest (9 at the default), where what's left is under 1%. The tuning window
  (`desktop/plasma-glass-tune.qml`, `qml6 -a widget`; install.sh installs it as `plasma-glass-tune`
  with a launcher) writes through QtCore's `Settings` (QSettings' INI, which KConfig reads, but neither
  takes comments after a value), at most every 0.1 s with `setValue()` and `sync()`: the declared
  properties write only 0.5 s after the last change, so a drag only arrived when it paused. A heartbeat,
  `[Ripple] tuning` (s since the epoch, 5 s ahead, every 2 s), keeps KRunner rippling and open when it
  loses the focus (`View::tuning`); a crash lets it run out. KRunner reads the file again before
  closing on focus loss, in case the heartbeat has only just come. Sliders snap to their step in code:
  Breeze draws a tick for each step. With no file, the waves measured the same as before (the right
  third moved 2.87 against 2.88 from the reference recording). Checked live in the preview, the tuning
  window beside KRunner and its sliders dragged with fakeinput: frost changed at once, speed, split and
  width with the next knock. The preview copies `plasma-glassrc` into its config, like your KDE files.
- **More natural waves** (2026-10-14, the user: "would look more natural with some noise / more waves
  summed together", workshopped as four prototypes, then all four kept as settings): chop, seven small
  plane waves across the glass at angles around the knocks' way, longer ones faster (30 px/s x
  sqrt(wavelength / `chopScale`)), coming and going with the knocks' waves (their summed strength) and
  kept off the rim over the bevel's width, where they added to the bevel's lean and sparkled; packet,
  two more profiles per knock, 0.6x as wide at 1.12x the speed and 1.6x as wide at 0.9x, so crests split
  and change as they go; front noise, value noise along the side (s) moving each crest by up to half a
  half-width and its strength by 60%, seeded per knock (KWin packs a seed from the knock's birth into
  `knocks[i].x` beside the side, KRunner the same); jitter, KRunner's: each knock's place (up to 20% of
  the side either way at 1), strength (`amp`, which scales its fade), width and time to the next (up to
  half a period). Defaults are the workshop's mix, chop 0.3, packet 0.7, front noise 0.5, jitter 0.6;
  all 0 is the old clockwork. The latest knock's chop, packet and front noise go for the whole glass,
  as with the edge fade. Cost in the preview: KWin 2.85-2.91 ms a frame against 2.78-2.79 with all
  four off, in the same run (the base drifted between runs that day: 1.97, 2.20, 2.78).
- **The liquid has momentum** (2026-10-14, the user: "trigger waves when moving around the element and
  it opening and closing, like the liquid inside has momentum"; `[Ripple] momentum`, 1, 0 for none).
  `View::floatingMoved(from)` comes from `moveFloatingTo`, `floatingPosition()` says where the window is
  on its screen (layer-shell clients can't ask the compositor), and busyRipple watches its own height
  for the dropdown's bottom edge. While anything moves a FrameAnimation samples the speed per axis (x,
  y, bottom edge) over the last 100 ms, and a swing detector turns changes of speed into knocks: once
  the speed has swung 400 px/s or more from its anchor and then held for 60 ms or come back 30%, the wall
  that pushed into the liquid knocks (speeding up rightwards the left wall, downwards the top one; the
  bottom edge when it speeds up upwards, as the dropdown folds or stops unfolding), from 60% of its
  length, as strong as the swing (`amp`, 1 at 1500 px/s, at most 1.3), at most once per side per 0.12 s;
  the anchor moves to the swing's peak. Logged in the preview (a scratch scene Meta+dragging KRunner with
  fakeinput, then folding and unfolding it), the first tries sent bursts: frame-to-frame speed flickered
  with the pointer's 60 Hz steps against 120 Hz frames (a start made three small waves), acceleration's
  sign flipped with that noise and split a stop's slowing into pieces too small to count (the stop sent
  none), overshooting speed settling back sent a small opposite wave (now a rebound: back within 0.2 s
  and under half the swing, it only moves the anchor), and over 60 ms a steady 1900 px/s drag still
  wobbled 500 px/s (hence 100 ms and 400 px/s). Then, twice over: one wave per start and stop per axis,
  one off the bottom per fold and per unfold's end. Momentum's knocks carry the busy knocks' side as
  `chopSide`, which the chop runs from, so it doesn't turn with them.
- **Liquid Glass Light's waves go beneath the frost** (2026-10-14: "the light version with frosted
  glass, the wave beneath the frosting", with a settings panel and the diffraction's etch size as a
  setting). KWin treats `liquid-glass-light` as Liquid Glass too: its own frost (`[Light] frost`, 5; it
  had KWin's own blur strength, 15 by default, before) and the bevel pass with `[Light]`'s bevel, off by
  default (the light style looks flat). While KRunner's waves run, `shaders/underlay.frag` runs between
  the background's copy and the first downsample: what's behind, seen from further in where a wave leans
  (`refraction`, 16 px x lean²), plus light where the waves crest in shards of colour, the Voronoi cells
  of a jittered grid `etch` px across (32), fixed to the window, each its own hue and sparkle, as
  busyfoil.frag's (`diffraction` 1.2, `saturation` 0.8). The blur's passes frost that instead of the
  plain copy, and the waves don't lean the glass on top. Under the frost the shards' size decides what
  shows: at 12 px they blur into a near-white haze, at 32 they show as soft patches of colour, at 72 as
  big blobs. The first defaults (frost 7, refraction 12, diffraction 0.8, etch 28) were too faint
  under the light glass's 62% white tint. In the preview (UHD 770, 744x346) KWin takes 2.69-2.73 ms a
  frame on light glass with the waves, 1.26 without them; the foil costs nothing measurable (2.72 ms
  without it), the full-size underlay pass and the heavier frost do.
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
  While it indexes, the busy ripple runs too (`busy` in RunCommand.qml includes `indexingProgress >= 0`;
  2026-10-16, the user: "while the index is loading enable the wave effect"), whether or not a search is
  running, and the last waves fade out as usual once it ends. Checked in the preview by motion in the
  query area: none without indexing, waves throughout with `INDEXING="3 7"` (over ColorfulCups, since on
  dark glass only KWin's bending shows them).
- **`Kirigami.Icon` rounds to standard sizes** (`roundToIconSize`): ask for 28 px and you get 22.
- **QQuickWindow sees every press as accepted after delivery**, even on empty space. Handle input
  in QML, as the KRunner drag area does (a MouseArea under the content).
- **KRunner's results model ends every refresh with `layoutChanged`**, which makes ListView recreate
  all rows. Per-row add transitions replay on every keystroke; that's why only the panel unfold is
  animated.
- **Similarity scores are compressed** (junk about 0.65, real matches about 0.7), so there's no
  junk threshold. Show the top N.
- **Files are found by name too** (2026-10-16, the user: it "doesn't seem to search/index file paths
  which makes it difficult to fuzzy search for files"). Two ways: every file in the folders (any type
  with `all_file_names`, the default) gets a vector of its name and path in the `names` table
  (`name_prompt()`, "title: NAME | text: Projects/…/NAME"; 626 files in 7 s on the CPU), searched beside
  the chunks, each file at its best; and `Index.match_names` matches the query's words against the
  path (relative to home) like fzf: a substring, or the letters in order from a word's start with 3 in
  4 starting a word or following the one before; every word must match and one of them in the name.
  Up to 3 of those go first (KRunner relevance 0.9-1). Without the word-start rule "lore" matched
  `vae·lor-e·state`. Checked on the main box's index: "pragconv", "fso armour", "t14 readme",
  "embedsearch py", "borrowed shift" put the file first, where meaning alone missed or ranked it
  lower; queries in words got the same or better (the `.config` files for "kernel config for the
  laptop"). Match ids are the paths now (no chunk ids). A word with slashes is matched folder by folder
  (`match_path`, 2026-10-16: "02/020/030" ranked `01/090-warm-hands/020-…` first, by meaning, since no
  path held all three): each part has to start a folder or the file's name (or a word in one), in order,
  a number only as a whole number ("02" isn't in "020-x"); parts in consecutive folders count 1.5x, the
  last one in the file's name a quarter more, earlier parts weigh more (1.5 down to 1: 02/020/010 beats
  01/020/030), and half the parts may go unmatched.
- **Where a result is** (2026-10-16, the user: the subtext was "vomiting the first line out of those
  files not giving me a file path"; wanted the path on hover at least, and ideally where each file sits
  at a glance, with the distinctions called out, like `fso/.../drafts/.../02/030` or ~/src vs /src).
  milou showed a match's subtext only on the current row (and duplicates), so other rows had no
  location at all, and ours put a passage first and the folder last, which ElideMiddle cut. Now
  `locations()` labels each result in the search service: its project (first folder under the indexed
  folder), its own folder, and the folders between that differ from another result's in the same project
  at the same depth, with shared runs of 4+ letters as "…"; the indexed folder ("~/Projects") only when
  the results span several (home and / count as roots, so ~/src and /src differ). No passage any more.
  `milou-section-headers.patch` shows a file result's subtext (any runner's, when its first url is
  file://) on every row, first line only, right-aligned (the user, "maybe right justify and give a nice
  expand animation"), and while the row is hovered its full folder (home as ~; the row already shows the
  name) unrolls to the left from under it: a clip anchored right widens from the short label's width to
  the folder's over 320 ms (OutCubic) while the short label fades out in 120 ms and the folder in over
  280, and both end in the file's own folder, which stays put. A folder that doesn't fit pans to its
  start once it has widened (a pause, 80 px/s, a longer pause, back at twice the speed). The pan animates
  0 to 1 and scales the overflow as it is at each frame: with the overflow itself as the animation's
  `to`, fixed when it started, it stopped short by the actions' width whenever the hovered row wasn't
  current yet ("not scrolling all the way"; reproduce with "cafeteria interrogation", hovering the
  second row and then the first). The actions on
  the current row fade in and the label layout's right margin slides open for them (220 ms) instead of
  re-anchoring, or the right-aligned text jumped left by their width on hover. A tooltip with the path
  came first, the same day: it covered the rows above ("remove that title it's blocking my view of other
  items. expand and scroll the text if too long on hover"), so file rows have no tooltips at all now. Preview: `HOVER="X Y" tools/preview/krunner.sh` rests the pointer
  there before the screenshot, and `HOVER="X Y, X Y" HOVER_HOLD=4 tools/preview/record.sh` moves it
  between rows while recording (screen pixels: at the recording's scale 1 and fixed place, rows of
  "02/020/030" sat at y 387 + 34 n, x 714). The preview's KRunner runs as claude, so it shows
  /home/aaralis/... rather than ~/... . To get real results in the preview as claude, register a D-Bus
  service for `local.embedsearch` in ~claude/.local/share/dbus-1/services running a copy of the service
  with `HOME=/home/aaralis`, and copy `embedsearch.desktop` to ~claude/.local/share/krunner/dbusplugins.
- **/etc is indexed** (2026-10-16, the user wanted system files; of /etc, ~/.config, /usr/src and /usr
  they picked /etc). `text_folders` (default `["/etc"]`) indexes every text file's text there whatever
  its extension. `extract_text` returns nothing for a file with a NUL in its first 8 KB, and in a text
  folder `looks_like_data()` drops text that's mostly runs over 40 characters (`/etc/ssh/moduli`, 674 kB
  of hex; the ~300 certificates). Files only root can read (32 on the main box) are logged as skipped
  once and found by name. On the main box /etc added 763 text files, 1.6 MB of text, 1,977 chunks, about
  4 minutes on the CPU. A user's existing config.toml lists its folders, so adding /etc to the defaults
  doesn't reach it: add `"/etc"` to `folders` there.
- **The search service's CPU per query** (2026-10-16, the user: "huge cpu spikes and lag when opening
  the dropdown" on the laptop, after the name search and /etc doubled its work). Over D-Bus a query cost
  0.5-1.3 s of the service's CPU for 0.3 s of wall time, and a typed query (a Match per key) 0.5-10 s.
  Two causes, measured with `time.process_time()` per stage: numpy's OpenBLAS pool spun on every core
  after each matrix product (`match_names`, pure Python, read 24 ms wall and 236 ms CPU), fixed with
  `OPENBLAS_NUM_THREADS=1` before numpy loads (search 140 to 11 ms CPU, a whole `find` 350 to 14); and on
  the GPU each new query length compiled its kernels anew (IGC on the CPU: 100-200 ms a key, seconds now
  and then), fixed by padding queries to a multiple of 16 tokens (masked, cosine 0.99999; a steady 49 ms
  a query). Typing a query then cost 80-590 ms of service CPU, the first ones after a restart more while
  the 16 and 32 token shapes compile. The index also no longer reloads inside a query (0.3 s): the
  indexing thread reloads it, at most once a minute during a run and once at its end. Tried and left
  out: `GPU_QUEUE_THROTTLE` LOW (55 to 39 ms CPU, but 55 to 76 ms wall). KRunner itself was not it:
  in the preview its CPU over a query and unfold read 870-890 ms with milou from before and after that
  day's changes (a wrapper sampling /proc/PID/stat as `KRUNNER`).
- **On dark glass KRunner no longer renders while waves live** (2026-10-16, the user: still "lagging a
  bit" on the laptop on battery, power-saver, CPUs near 1 GHz). The busy ripple's `FrameAnimation`
  only times the knocks there (KWin draws the waves; busyRipple is hidden), but a running frame
  animation keeps Qt's render loop going, so KRunner rendered the same frame at the screen's rate and KWin
  blurred each one anew, for as long as waves lived (13.5 s with the laptop's `[Ripple] lifetime`). Now a
  `Timer` (`knockTimer`) wakes for the next knock or the oldest wave's end on dark glass, and the frame
  animation only runs where busyRipple draws (Light with its sheen). Typing "kernel config laptop" in
  the preview: KRunner rendered 207 frames instead of 755 and used 830 ms of CPU instead of 1,020 (main
  box); KWin's frames were the same. Measured with `QSG_RENDER_TIMING=1` (render-loop lines in
  app.log), KWin's `KWIN_LOG_PERFORMANCE_DATA=1` (written to KWin's working directory), and keys typed
  by fakeinput as `HOVER_INPUT` after `krunner.sh OUT " "` (an empty query means the default one).
  The laptop's own `plasma-glassrc` is heavy: `[Glass] frost=15`, `bevelWidth=60`, `[Ripple]
  lifetime=13.5`. The preview runs there too (configs copied as on the main box; no EGL override, it has
  only the Intel GPU, and its render node is open to claude).
- **KDE's Dark Mode switch put the Plasma Style back to Breeze** (2026-10-16, the user: "i used the light
  mode switch on the UI and it somehow messed up my theme on the desktop"). The tray's Brightness and
  Color applet has a Dark Mode switch (`DarkModeControl` in libbrightnesscontrolplugin; Quick Settings and
  the lookandfeel kded read the same keys) that applies the global theme named by `kdeglobals [KDE]
  DefaultDarkLookAndFeel` / `DefaultLightLookAndFeel`, Breeze Dark and Breeze by default, whose
  `[plasmarc][Theme] name=default`. Applying one writes its defaults to `~/.config/kdedefaults/` (in
  every Plasma process's `XDG_CONFIG_DIRS`) and removes the user's own entries, so `plasmarc` went empty and
  the style fell to Breeze. It happened 10-15 06:42-06:43 (two xsettingsd reloads, `kdedefaults/package`
  and `kdeglobals` written) and only showed at the next login, 10-16 14:03: the running plasmashell kept
  its style. Now `theme/look-and-feel/` has two global themes, `plasma-glass.liquid-glass{,-light}`
  (Breeze's defaults with our style, no wallpaper or layout), install.sh installs them and makes them the
  default dark and light ones, and plasma-glass-mode applies them (`plasma-apply-lookandfeel`) instead of
  setting style, colours and icons one by one. Applying rewrites `~/.config/plasmarc` too, so KWin's
  KDirWatch on it still fires, and it reads the inherited value through KConfig. Tested in a sandbox
  (`env -i` with scratch `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_DIRS=<scratch>/kdedefaults`,
  `QT_QPA_PLATFORM=offscreen`, `dbus-run-session`): both listed, each applies style, colours, icons and
  package, and an explicit `plasmarc` entry gives way.
- **KRunner ran in background.slice** (2026-10-16, the user: the dropdown "at about 20fps" on the laptop,
  worse in power-saver, with "a 300ms lag after first key press"). Plasma's `plasma-krunner.service` has
  `Slice=background.slice`, CPU weight 30 against app.slice's 100, and Claude Desktop ran at nice -8 beside
  Firefox playing media; in power-saver (CPUs near 1 GHz) KRunner lost the CPU exactly while drawing. The
  preview never showed it (no load there): KRunner's frames were even there in power-saver, and its rows
  cost the same with the morning's milou, the day's, and `reuseItems` (150 ms of polish over a typed
  query), so the timer change and the row changes weren't it. Measured in the real session with a
  temporary drop-in (`Environment=QSG_RENDER_TIMING=1 "QT_MESSAGE_PATTERN=%{time boot} %{message}"`,
  the user typing three queries): before, 34 fps, 40 gaps over 50 ms, polish up to 112 ms, swaps up to
  44 ms; with install.sh's `plasma-glass-priority.conf` drop-in (`Slice=session.slice`, and `Nice=-5`
  where `ulimit -e` allows it, or Nice= fails the service), 50 fps, 9 gaps, polish up to 50 ms, no swap
  over 20 ms. `perf` is on the laptop now (`dev-util/perf -gtk` in package.use); a system-wide record
  (`perf record -a -F 199`) is what showed KRunner at 0.8% of the CPU beside the apps. Profiling the
  preview at 150 fps capture (unfold.sh) misleads here: the capture itself is the biggest load, and its
  stalls were its own.
- **The dropdown's momentum waves restarted and rode down the glass** (2026-10-16, the user: "the wave
  animation seems to be somehow restarting every frame", then "the wave is translating down the element
  as the window opens"). Counted with `dbus-monitor --session "type=method_call,member=Knock"` in the real
  session: 11 bottom-edge knocks in 6 s, most at the full 1.3, in threes 0.3-0.9 s apart. Results arrive
  in batches, so opening unfolded, stopped and unfolded again, and each stop (the bottom edge speeding up
  upwards) knocked; and a knock while the dropdown still grew rode down with it, since a bottom wave is
  placed from the current bottom edge (KWin's and busywaves' window coordinates). Now the bottom edge's
  swings only remember the strongest, and `settling` (a 150 ms Timer, restarted by every change of height)
  sends one wave once the dropdown has stopped, at most one every 1.2 s. The preview never showed it: its
  query arrives at once and unfolds once (2 knocks in a session). A wave can still move if the height
  changes later in its life (the user: "if a wave is already propagating it still gets pulled down with
  the bottom of the window as it opens"), so each knock now keeps the window's size when it struck (KWin's
  `LiquidGlassKnock::size`, KRunner's `w0`/`h0`) and a bottom or right wave's distance travelled gets the
  edge's move since (`knocks[i][2] = speed * age + moved`, the same in RunCommand.qml's `kv`): its crest
  stays where it is on screen while the window grows or shrinks. KWin's half only runs after a relogin.
- **The dropdown reopened half unfolded, and flickered while typing** (2026-10-16, the user: "stuck between
  open and close", rare; "flickering between open and closed when quickly typing then backspacing
  repeatedly"). Caught with a KWin script logging KRunner's frameGeometry height on every change
  (`KRUNNERSIZE` in the journal; loaded over org.kde.kwin.Scripting, nothing in KRunner): one session opened
  at 121 px against an empty 69 and stayed so until the first key, and typing and deleting reversed the
  height 356 times in 2.5 min, folding shut and unfolding every 0.2-0.5 s. The window followed only
  changes of the content's implicitHeight, so after it was hidden mid-fold (clicked away) it reopened at
  the height it had; `View::fitContent()` now also runs as it shows (and calls `update()`: a layer-shell
  size only applies with a commit). Tried and taken out the same day: unfolding at once but folding only
  after the results had stayed fewer for 200 ms (`foldLater`). The rows go the moment the query empties,
  so the empty glass then waited before folding ("the entire list is disappearing the moment the dropdown
  starts closing"), and the list's height estimate overshoots while its rows are made, which then stayed
  ("it increases in size beyond the size of the list"). The flicker from typing and deleting fast is the
  dropdown following its results, as it always has. (A Timer inside the QQC2 ScrollView broke it: it takes
  its children for content, and the list stopped being its scrolling area; keep such things outside.)
- **The dropdown unfolds in 350 ms** (2026-10-16, the user: "the fast animation + 60hz is making it feel
  more choppy than it needs to be"; it looked smoother on the laptop's denser screen). It took Plasma's
  long duration, 200 ms by default (AnimationDurationFactor unset on both machines): with OutCubic, 12 steps
  at 60 Hz and the first a quarter of the way. Now `Kirigami.Units.longDuration * 1.75`, still scaled by
  that factor and off with reduced motion: 21 steps. At 350 ms OutCubic "looks a little sluggish at the
  start", so it's OutQuart, the first step 18% of the way (OutCubic's 14) and a longer settle. Recorded side by side at
  `REFRESH=60000` with record.sh (`QUERY2` must be non-empty: an empty one counts as none, so a fold can't
  be recorded that way).
  `tools/preview/krunner.sh` takes `HOLD` (s before HOVER_INPUT and the screenshot, default 8), used to
  script open/close cycles over the preview's bus as a `KRUNNER` wrapper.
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
  reproduce it (one GPU). The 2080 Ti's link runs at PCIe 3.0 x8 (it can do x16), which bounds any
  copy between the GPUs at about 7 GB/s. Both Qt patches are installed here (2026-10-12), so KRunner
  renders on the GPU with no drop-in. KWin got no real-time priority until 2026-10-13 ("Failed to gain
  real time thread priority" at every start, all threads SCHED_OTHER, though `kwin_wayland` has
  `cap_sys_nice=ep`): the kernel (gentoo-dist) has `CONFIG_RT_GROUP_SCHED=y`, which refuses SCHED_RR to
  tasks outside the root cgroup until their group gets RT runtime, and cgroup v2 can't give it. GRUB
  now passes `rt_group_sched=0` (`GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, normal entries
  only), and KWin's main thread, its per-screen commit threads and its libinput thread run SCHED_RR.

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
