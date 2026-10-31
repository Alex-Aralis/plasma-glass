# plasma-glass: notes for development

Liquid Glass Plasma Styles, semantic KRunner search (EmbeddingGemma 2 on the Intel iGPU via OpenVINO),
the Liquid Glass effect (a KWin plugin: the glass's bevel and frost, the liquid) and Portage patches for
KRunner, notification popups, milou, the panel and KWin (Window Behavior's tabs). Gentoo, Plasma 6.7.5, KDE Frameworks 6.30, Qt 6.11.2,
Wayland. User docs are in README.md; this file covers how to work on it.

The fixes for KDE and Qt bugs found along the way (KWin's frame pacing, render GPU copy, crash at logout
and activation tokens; KSvg's colours after a style switch; Qt's resize glitches and 60 fps animations;
the notification body's cursor; KRunner's background.slice) were split out into kde-fixes on
2026-10-17 (`~/Projects/kde-fixes`, https://github.com/Alex-Aralis/kde-fixes), one patch per fix, with
their notes in its AGENTS.md. A fix for a bug stock KDE or Qt has goes there; a change plasma-glass's
look or search needs stays here. Both repos' patches sit side by side in /etc/portage/patches (they
change different files), and each repo's check applies the other's installed patches with its own.

## Layout

| Path | What |
|---|---|
| `search/embedsearch.py` | search service: indexer, KRunner D-Bus runner (`local.embedsearch`), CLI. Installed copy: `~/.local/share/embedsearch/` (service `embedsearch.service`) |
| `search/settings_index.py` | builds `search/settings-index.json` (System Settings option labels, page, tab; the Shortcuts page's Common Actions; Qt's key names) from the installed packages' source tarballs; re-run after a Plasma upgrade |
| `search/export_model.py` | one-time PyTorch to OpenVINO export with a parity check (run by install.sh in a throwaway venv) |
| `theme/liquid-glass/generate.py` | draws the three styles (`liquid-glass`, `liquid-glass-light`, `liquid-glass-dark-frost`) into `~/.local/share/plasma/desktoptheme/` |
| `theme/icons/` | the start menu's app grid (`plasmaglass-app-grid-symbolic.svg`), which install.sh puts in hicolor |
| `patches/kde-plasma/{plasma-workspace,milou,kwin,plasma-desktop}/*.patch` | Portage user patches, one per package (`plasma-workspace-tweaks.patch`, `milou-section-headers.patch`, `kwin-window-behavior-tabs.patch`, `plasma-desktop-tweaks.patch`; the KWin one was `kwin-fixes.patch` until 2026-10-17 and `kwin-liquid-glass.patch`, with the glass, until 2026-10-22; the plasma-desktop one `plasma-desktop-shortcut-search.patch` until 2026-10-22) |
| `kwin-effect/` | the Liquid Glass effect: KWin 6.7.5's blur effect (plugins/blur) with the glass, a plugin of its own (`liquidglass.cpp`, `shaders/`; `portage-hook.sh` rebuilds it after KWin merges). The notes below from before 2026-10-22 name the patch's files: blur.cpp is liquidglass.cpp, `BlurEffect` `LiquidGlassEffect` |
| `tools/kwin-effect.sh` | the effect: `build` (a new id each time), `install [LIB]` (root: KWin's plugin folder links `liquidglass.so` to it), `reload` (the running KWin swaps it in over D-Bus, checks `Build()`), `enable`/`disable` (kwinrc), `status` |
| `desktop/` | KRunner plugin, systemd and D-Bus files, `plasma-settings.sh` (krunnerrc, kdeglobals, plasmanotifyrc), `krunner-shortcut.sh` (KRunner on Meta+Space, or back on Alt+Space), `kickoff-icon.sh` (the app grid on the start menu's button, or the Plasma logo back), `plasma-glass-tune.qml` (Liquid Glass Tuning: the liquid and the dark glass, live) |
| `tools/patch-dev.sh` | patch workflow: setup, edit, check, refresh, install; `krunner` builds a test copy, `kwin` compiles the edited KWin files (with kde-fixes' installed KWin patches in the tree), `kcm-keys` builds the Shortcuts page and KRunner's Global Shortcuts runner, `kickoff` the start menu, `plasmashell` plasmashell (for `tools/preview/panel.sh`) |
| `tools/check-patches.sh` | patches apply, alone and with the other user patches installed for the package (kde-fixes'); patched QML loads under qml6 with stubs; patched KRunner C++ syntax-checks |
| `tools/screenprobe/screen.sh` | probes on the real screens (small, never focused, ask first): `fps` measures Qt Quick frame rate and animation speed per screen, `glass` shows the style's glass over a grey square (screenshot or by eye) |
| `tools/preview/` | screenshots on a virtual KWin display: `krunner.sh` (`SWITCH`: across a global theme switch), `settings.sh` (System Settings on a page with arguments), `dialog.sh`, `popup.sh` (a real plasmashell tray popup), `panel.sh` (your panel, floating or docked, screenshot or video), `elements.sh`; `unfold.sh` measures KRunner's resize animation frame by frame (`frames.py`), `frametimes.sh` its dropped frames (`frametimes.py`, from KWin's frame log); `record.sh` records KRunner into a video (demos); `fakeinput.c` for pointer input |
| `tools/liquid/` | the liquid off screen: `liquid.sh` runs a numpy model of `fluid.frag`'s ripples with the user's tuning (`drag` speeds, `click`, `check`: pass/fail for the press keeping up, its trench, a plain click's rings); `record.sh DIR` logs drags across Kickoff in the preview (`KWIN_LIQUID_GLASS_CLICK_LOG`: every step, the real liquid read back each frame) and `liquid.sh compare DIR` holds the model against it. Keep `liquid.py` in step with `fluid.frag` and `runLiquid` |
| `desktop/test-notifications.sh` | sample popups (clickable, long and scrolling, image, critical); installed as `plasma-glass-test-notifications` with a "Test Notifications" launcher |

## Dev loops

- **Style:** edit `generate.py`, then `tools/preview/krunner.sh /tmp/k.png "query"` (or
  `STYLE=repo-light`, `STYLE=repo-dark-frost`). Apply with `./install.sh --no-search --no-settings`, which regenerates the SVGs,
  drops Plasma's cached renders and reapplies.
- **Patches:** `tools/patch-dev.sh setup`, edit under `~/.cache/plasma-glass/dev/b/<pkg>/`, then
  `refresh` and `check`, then `sudo tools/patch-dev.sh install`. After the build, run
  `systemctl --user restart plasma-plasmashell.service` (notifications) and `kquitapp6 krunner`.
  For notification changes, run `plasma-glass-test-notifications` and check
  `journalctl --user -u plasma-plasmashell.service` for QML errors. The real popups only appear in
  plasmashell, so the user looks at them; `tools/preview/dialog.sh` only approximates them.
  milou rebuilds in about 2 min, plasma-workspace in about 25 min on the laptop (about 6 min on the
  main box) and kwin in about 3½ min on the main box. A new KWin runs from the next login.
  `tools/patch-dev.sh kwin` compiles the edited KWin files first (20 s the first time). The dev trees
  hold plasma-glass's changes only: kde-fixes has its own (a git repo per package, its
  `tools/patch-dev.sh`). Trees set up before 2026-10-17 still hold the fixes in `b/kwin` and
  `b/plasma-workspace` (Body.qml), and a `refresh` from them would put them back here: `FORCE=1
  tools/patch-dev.sh setup` first.
- **KRunner C++/QML without an emerge:** `tools/patch-dev.sh krunner` builds just KRunner from the
  edited tree (about 20 s the first time, then seconds) and refreshes a milou QML overlay. Preview:
  `QML_IMPORT_PATH=~/.cache/plasma-glass/dev/qml KRUNNER=$(tools/patch-dev.sh krunner) tools/preview/krunner.sh /tmp/k.png "q"`.
  `tools/preview/fakeinput.c` (built by `common.sh`) sends pointer input to the preview's KWin, and a
  KWin script can print `frameGeometry` of each window, so drags can be measured, not just eyeballed.
- **Demos:** `tools/preview/record.sh OUT.mp4 "query"` (same `QML_IMPORT_PATH` and `KRUNNER` as above)
  records KRunner's window with the busy feedback running (`BUSY=0` for none; `SECONDS_CAPTURED`,
  default 6) at 60 fps, through KWin's `CaptureArea` on a 120 Hz virtual screen, and keeps a lossless
  `OUT.mkv`; `QUERY2` follows `QUERY2_AT` s in, so a query of `""` records the results unfolding.
  `INPUT=file` sends fakeinput commands as it starts recording, e.g. a Meta+drag (`key 125 down`, `move`,
  `down`, `by 20 0` and `wait 16` steps), with `TOP` (KRunner's top, a share of the screen) and a `PAD`
  wide enough to keep the window in view. For a side-by-side the pushes have to line up: both
  recordings start 5.5 s after KRunner, and with the knocks two of them came out within a frame of each
  other in the 1.2 s cycle (`ffmpeg -i a.mkv -i b.mkv -filter_complex hstack`; drawtext labels can't hold
  a colon). To see where waves move, difference frames a few hundred ms apart; to see the liquid itself,
  read the waves texture back (`glGetTexImage` in a scratch build) and draw its slope as colour.
- **The glass (Liquid Glass effect):** edit `kwin-effect/`, then `KWIN_EFFECT=repo tools/preview/krunner.sh ...`
  (or panel.sh, record.sh: the preview's KWin loads this checkout's build; unset, it takes the installed one
  if there is one, as your KWin does). On the desktop, `plasma-glass-reload-kwin` (or `tools/kwin-effect.sh
  build`, `sudo -n tools/kwin-effect.sh install LIB`, `as-aaralis .../tools/kwin-effect.sh reload`) swaps it into
  the running KWin in seconds; no relogin, nothing closes. `tools/preview/effect.sh` checks the swap itself
  (built-in blur, then two builds, each confirmed by `Build()`).
- **KWin in the preview:** after `tools/patch-dev.sh kwin`, `ninja -C ~/.cache/plasma-glass/dev/kwin/build
  kwin_wayland` links a whole KWin (2¼ min the first time on the main box, then about 12 s; effects
  like blur are built in), and `KWIN_WAYLAND=~/.cache/plasma-glass/dev/kwin/build/bin/kwin_wayland` runs
  it as the preview's compositor instead of the installed one (`KWIN_ENV` for its environment). KWin
  only redraws what changes, so to see or measure the blur behind KRunner over time, scroll the
  wallpaper: `WALLPAPER_PAN=40` (px/s; with record.sh, since screenshots crop to what changed). A still
  scene made KWin's GPU time read 0.05 ms a frame instead of 2.
- **Qt without an emerge:** kde-fixes' `tools/patch-dev.sh qt` builds its patched Qt libraries and
  prints the environment that loads them into one app: `KRUNNER_ENV="$(~/Projects/kde-fixes/tools/patch-dev.sh
  qt)" tools/preview/unfold.sh`. Its AGENTS.md has the details.
- **Resize glitches:** `tools/preview/unfold.sh` captures ~150 fps while KRunner's results unfold
  and fold and prints `top edge misplaced in N` (old frame shifted) and `N distinct text layouts`
  (old frame stretched; 1 = clean). `KRUNNER=`, `KRUNNER_ENV=` and `KWIN_ENV=` pick the build and
  environment. The stretch comes and goes, so compare several runs. To see which buffer a glitched
  frame came from, run with `KRUNNER_ENV=WAYLAND_DEBUG=client` (the log is the preview's `app.log`,
  times in UTC) and line it up with the frames (`meta.json` has the capture's start time, `t0_wall`).
  The glitches it found were Qt's (kde-fixes' AGENTS.md has the measurements).
- **Frame rates:** the virtual display runs at 60 Hz, so check refresh-rate behaviour on the real
  screens with `tools/screenprobe/screen.sh fps X,Y [X,Y...]` (positions from `kscreen-doctor -o`;
  `ENV=...` for a patched Qt, `QSG_RENDER_LOOP=basic` for the GUI-thread loop). Qt Quick ran at 60 fps
  on the faster screens until kde-fixes' qtdeclarative fix; its AGENTS.md has the numbers. Always say
  before putting windows on the user's screens.
- **Search:** edit `search/embedsearch.py`, copy it to `~/.local/share/embedsearch/`, then
  `systemctl --user restart embedsearch`. Use `embedsearch search "q"` to test.

## Rules learned the hard way

- **Run `tools/check-patches.sh` before every emerge.** qmllint misses runtime-only QML errors.
  Example: `background: Item {}` together with the existing `background.z: -2` ("Cannot assign a
  value directly to a grouped property") built fine and then KRunner's UI failed to load.
- **Previews need a Plasma session's environment.** Without `XDG_CURRENT_DESKTOP=KDE` (and
  `KDE_FULL_SESSION`, `KDE_SESSION_VERSION`) Qt skips KDE's platform theme, so apps in the preview took
  Qt's generic "Sans Serif" 9 pt (Liberation Sans) instead of the user's Noto Sans 10 pt: text about 10%
  small in another face, unnoticed until 2026-10-28. `session.sh` exports them now.
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
- **Resizing glitches, 60 fps animations and frame pacing were Qt's and KWin's bugs**, not KRunner's:
  Qt Quick drew the frame after a resize at the old size (NVIDIA's GUI-thread loop; Mesa's threaded loop
  at high refresh rates), Qt sent the viewport size before the buffer drawn for it, Qt Quick animated at
  the primary screen's rate, and KWin held frame callbacks until it slept and copied the iGPU screens'
  frames through the CPU. All fixed in kde-fixes, whose AGENTS.md has how each was found and measured.
  When something looks like KRunner jumping or stuttering, measure it there before blaming the QML.
- **KRunner's busy feedback and its momentum are a simulated liquid** (2026-10-16, the user: "right now
  the 'waves' are just some animations. is it possible to make the waves more simulation based instead of
  animation based? it would be much less jank that way", then "we don't need to keep the 'knock' idea. it
  could be more of a 'push' on the edge over time, or another perturbation somewhere of the fluid directly
  in a region", and "the effect on move would be better as a 'sloshing' cause by momentum rather than a
  reuse of the thinking pulse"). KWin runs it (`kwin-liquid-glass.patch`: `runLiquid()` in blur.cpp,
  `shaders/fluid.frag`, `shaders/surface.frag`) in each Liquid Glass window whose process asked for it with
  `org.kde.KWin.LiquidGlass.Stir(busy, side, at)` (matched by the caller's PID and kept per process, since
  KRunner's window is a new one each time it opens). It's linear shallow water on a staggered grid (a texel
  per cell: its height, its right and bottom faces' velocities, and whether it's wet), stepped forward then
  back on the GPU between two RGBA32F textures, in even steps of at most 0.5 cell / c up to the frame's
  target pageflip time (`OutputFrame::targetPageflipTime()`, so the steps follow the refreshes; at most
  0.1 s after a stall). Two layers, since on real water long waves outrun short ones: ripples (3 px cells,
  `[Ripple] speed` 120 px/s, damped over `damping` 36 s and by a sponge along the rim, 32 px wide, that takes
  up what `reflection` 0.3 doesn't send back) and swell (8 px cells, `sloshSpeed` 900 px/s, `sloshDamping`
  1.5 s, all of it sent back). The window's place and size go through critically damped followers (3 Hz:
  the pointer's 60 Hz steps against faster frames become a change of speed over about 0.15 s), and the
  liquid is pushed against the acceleration of the glass's centre, the swell 30x and the ripples 0.15x at
  `momentum` 1 (as if the liquid were that much deeper: a change of speed of 1000 px/s sloshes the swell
  about as far as a push's wave leans the glass). While busy, a stretch of one side (`side`; KRunner sends
  `at`, beside the query while closed and `position` of the way down once results show) pushes in over the
  time a wave `width` wide takes to pass (a sine pulse's 1/e half-width is 0.38 c t) and eases back out over
  the rest of the `interval`, as far as it came in; the side bows in most at `at` and not at all at its
  corners (the knocks' flex, sin² warped so its peak lands there; `strike` px move as one). Its peak speed
  makes a wave whose steepest slope is 0.8 in a straight channel (`s_pushSlope`; at 0.5 the waves moved the
  picture a third as much as the knocks had, since they spread as real waves do). `stir=press` presses on
  the surface just inside the rim instead, a Gaussian `width` px wide, which rings out in circles. A breeze
  (`chop` 0.3, gusts `chopScale` 40 px across: gradient noise in space and time, since value noise showed
  its lattice as squares) presses here and there while busy, rising over 0.5 s and dying down over 1 s
  after; `jitter` varies each push's place, strength, length and timing as it did the knocks'. The surface
  pass (half the background's size) samples both layers bilinearly (RGBA32F filters on desktop GL; on GLES
  the liquid is off), each sample pulled at least a cell in from the rim so the dry cells past it don't
  count, and writes the slope and the ripples' height (over a fresh crest's) into the waves texture the
  bevel pass read before. It runs while busy and until the ripples have settled to about 5% after the
  last push (damping, and what the rim takes each crossing: 11 s at 744x503 by default, at most 15) or the
  swell after a move (3 x `sloshDamping`), fading out over its last 2 s; then it lets go of its textures
  and KWin stops repainting. KRunner draws nothing of it: busyStir in RunCommand.qml only calls
  `View::stir()` as it gets busy or done, as the push's place changes (after 100 ms) and as the window
  shows, so the window gets the liquid busy or not. The busyripple, busywaves and busyfoil shaders and the
  knocks went (up to commit 9061290 the waves were analytic: a crest with a ringing train per knock, up to
  8 at once, worked out again per pixel in KRunner and in KWin's ripple.frag), and with them Liquid Glass
  Light's sheen on top of the glass (`[Light] layer`), which can't follow a liquid only KWin has. Designed
  in a numpy prototype of the same discretization first (stability, the push's and momentum's gains), then
  in the preview. Bugs on the way: the grid has to start outside the glass (cell i's centre at (i - 0.5)
  cells), or the left and top rims had no faces and only the corners' arcs pushed; and the dropdown first
  moved the bottom rim as a piston, but OutQuart starts it at about 5000 px/s against the swell's 900, and
  each row it uncovered started as a step, which tore the cups behind into jagged bands: now growing counts
  as the centre's acceleration, and a cell the glass grows over starts at its wet neighbours' level. Then,
  the same evening (the user, after trying it installed: "when opening and closing the dropdown the liquid
  exhibits a very strong short wavelength vibration-like effect that i don't like or at least should match
  the wave width setting"; reproduced in the preview by typing and deleting with fakeinput while recording,
  the cups behind torn into jagged bands): the glass can grow by many cells in a frame (OutQuart's start,
  results arriving in batches), and only the first new row had a wet neighbour, so the rest started at 0
  next to liquid the momentum had heaped up, a step every frame; a new cell now takes the level of the
  nearest liquid above it or to its left (up to 32 cells). And the followers pass a window's quick wiggles
  on as acceleration (a critically damped follower's acceleration doesn't fall off above its frequency), so
  each layer now feels it smoothed again: the ripples over the push's time to push in (a jolt makes waves
  as wide as `width`), the swell over at least 0.15 s. Straight momentum waves (the user: "add some kind of
  slightly off the edge of the border wavy surface that generates the momentum waves, and maybe the
  reflections as well"): the liquid's edge, the shore, runs `shore` px in from the rim and wanders by up to
  that much either way (`shoreScale` px bends), and its floor is uneven (`floor` 0.35: c² times 1 +- 0.35
  in `floorScale` 220 px swells, waves faster where it's deeper, the steps sqrt(1.35) shorter for it), both
  as three plane waves at odd angles (sines: cheap, and no lattice). The shore alone barely bent the broad
  swell (slope maps with and without looked alike, and a 20 px shore left a dead band): broad waves
  straighten out a short way from any bumpy wall; the floor keeps bending them as they cross. The surface
  pass reads only wet cells (the filtered height over the filtered wetness, since dry cells hold 0 and say
  so in w) and fades the lean out over the last cell before the shore; pulling samples in from past the
  shore left speckles where it switched. Compared by dumping the waves texture from KWin every 0.1 s
  (`glGetTexImage` in a scratch build) and drawing the slope as colour, over a Meta+drag. Cost
  in the preview (UHD 770 through Mesa, KRunner 744x503 at scale 1 over ColorfulCups, from KWin's
  `/proc/PID/fdinfo` `drm-engine-render`, which the installed kwin_wayland's file capability closes; main's
  KWin ran from a dev build in a directory of its own, as a renamed copy won't start: KWin's own Qt
  platform plugin wants the name): busy, 4.51-4.59 ms a frame against the knocks' 4.27-4.29; settling after
  a move about 5 ms (300 ms/s at 60 Hz) against one or two knocks' 3.4, since the waves take the bevel
  pass's per-pixel path over all of the glass. `KRUNNER_BUSY_DEMO=1` keeps KRunner busy, to look at it
  (also in `tools/preview/krunner.sh`, and `tools/preview/record.sh` records it).
- **The panel is glass, docked or floating** (2026-10-22, the user: "plasma glass to the taskbar in both
  forms, attached and detached"). Plasma's Panel.qml (plasma-desktop's desktop package) draws
  `widgets/panel-background` twice over: `floatingTranslucentItem` (all borders, inset by the floating
  gap, 8 px unless the style has a `floating` prefix) while it floats or animates, `translucentItem`
  (PanelView's enabled borders: none against the screen's edges) once docked; `thick-*` margins pad the
  applets. A floating panel docks whenever a window touches it (maximized), and with adaptive opacity,
  Plasma's default, it then cross-fades to `solid/widgets/panel-background` (Breeze's: opaque), so the
  docked form was never glass. The styles' plasmarc says `[AdaptiveTransparency] enabled=false`
  (`PanelView::opacityMode()` is then Translucent whatever the panel's setting, and its settings drop the
  opacity choice), so it stays glass; no solid variant is drawn. generate.py draws the panel as the
  dialogs' frame (`panel_svg()`: R, C, T, SHADOW, GLOW_DEPTH and MARGIN swapped for `PANEL_*` while it
  runs), 16 px corners, as two 26 px ones don't fit across a 46 px panel. KWin (`kwin-liquid-glass.patch`)
  had taken the glass for a frame only when a corner pixel was missing from the blur region, then rounded
  every corner by 26: a docked panel got KWin's own blur (strength 15, so it looked like Breeze's), and a
  floating one corners that didn't match. Now `liquidGlassCorners()` reads each corner's radius off the
  region (r² (1 - π/4) is what a quarter circle leaves out of its square; to about a pixel, square
  corners 0), dock windows count as glass with none, and edges within half a pixel of the window's
  output's edge are moved out past the bevel in the bevel pass's box, so a docked panel bends what's behind
  only along its top edge (and its ends, when it doesn't span the screen). A bevel 24 px wide covered all
  of a 46 px glass from both sides, so on thin glass it's at most `s_liquidGlassThinBevel` 0.35 of the
  short side (16 px on the panel) with its refraction scaled alike (9 px to 6), which leaves KRunner (69 px
  folded) and the popups as they were: KRunner over ColorfulCups with the waves off
  (`KWIN_LIQUID_GLASS_RIPPLE=0`) came out the same before and after but for its text cursor (22 px).
  `tools/preview/panel.sh` runs plasmashell with your layout (popup.sh's private bus);
  the activity manager there has this account's activity, not yours, so it rewrites the desktops'
  `activityId` first (or plasmashell makes a new desktop with the default wallpaper), and `COLORS` applies
  a colour scheme (`plasma-apply-colorscheme` needs `QT_QPA_PLATFORM=offscreen`). Then (the user, the same
  day: "remove the shadow when attached, keep the detached menus when attached"): PanelShadows gives a
  panel shadow tiles on its enabled borders only, the same `widgets/panel-background` pieces docked or
  floating, so a style can't drop them for one; `plasma-workspace-tweaks.patch` (now with `shell/`) gives it
  none while `m_floatingness` is 0 (`shadowBorders()` in panelview.cpp). The floatingness animation writes
  the QML property first, whose shadow-margin bindings call `updateShadows()` before PanelView's own
  `m_floatingness` changes, so the shadow came out for the previous step and stayed; it's updated again as
  the panel enters or leaves 0 and when the animation ends. Popups float (a `largeSpacing` gap, all borders:
  `PopupPlasmaWindow` keeps every border whenever its margin isn't 0) when the containment has
  `ContainmentPrefersFloatingApplets` (CompactApplet, the tray, the task manager's group dialog), which
  Panel.qml sets only while the panel floats, or for a never-floating panel with "Floating applets";
  `plasma-desktop-tweaks.patch` (now with `desktoppackage/`) keeps it for a floating panel docked by a window.
  Checked with `tools/patch-dev.sh plasmashell` (plasmashell in KRunner's build tree, 30 s),
  `PLASMASHELL=... SHELL_PACKAGE=~/.cache/plasma-glass/dev/b/plasma-desktop/desktoppackage
  tools/preview/panel.sh` (`DOCK=1 POPUP=kickoff CROP=760`), and the rows above the docked panel (the
  shadow darkened them from 46 to 38 over the maximized window; flat after). Task manager and pager
  highlights are still Breeze's (`widgets/tasks`, `widgets/pager`: a style's file replaces Breeze's whole,
  so glassy ones need every element, progress and group arrows too).
- **Docked, the panel has no rim, and the start button sits centred** (2026-10-31, the user: "i don't like
  the rim on the collapsed taskbar, pitch me some better styles. also not a huge fan of the start menu icon
  on the left with it's weird spacing"; of the options rendered in panel.sh (no rim, a shadow cast by the
  window above, a soft band of light, the tint thinning at the top, a dark hairline; a glint and an etched
  line tried too) and five start buttons, "app grid + seamless"). Glass attached to the screen's edge has no
  rim, as in Apple's Liquid Glass; the floating panel keeps its own. Panel.qml drew both forms from the same
  pieces (`[location, ""]`), so a style couldn't tell them apart: `plasma-desktop-tweaks.patch` gives the
  docked items (`translucentItem`, `opaqueItem`) `["docked", location, ""]`, and generate.py draws
  `docked-*` (the glass without rim or glow), `mask-docked-*` and `docked-hint-*`, since KSvg reads a
  prefixed frame's mask and margins under its prefix. A FrameSvgItem takes the first prefix whose `-center`
  the style has, again on every theme change, so other styles look as before and a style switch picks it
  up live. Where a dark window meets a dark part of the wallpaper the bar's top is faint now, only its tint
  setting it apart. The start button: Kickoff's cell is 38 px at 16 px in the panel's window (the 8 px
  floating gap and 8 px of margins), its icon rounded to 32, and the Plasma logo (start-here-kde-symbolic)
  fills 23x24 of that; docking grows the glass 8 px out to the screen's edge while the applets stay put, so
  docked the logo sat 23 px from the edge and 13 from the pager. Kickoff (`applets/kickoff/main.qml`) at
  either end of a panel now moves its icon halfway between the glass's edge and the next applet's cell,
  (edge + spacing - cell) / 2 rounded to whole pixels, by a `Translate` it also hands CompactApplet's
  `expandedFeedback` (the highlight while the menu is open). The edge is Panel.qml's `leftFloatingPadding`
  (its root found as the ancestor with `floatingness`), the neighbours the `AppletContainer`'s siblings. The
  cell's place is added up from each ancestor's x, not `mapToItem`: a binding only follows what it reads,
  and the containment, centred on the glass with `anchors.centerIn`, shifts back by a pixel just as the
  dock animation ends, which left the icon a pixel off whenever nothing it read changed then. The icon is
  `plasmaglass-app-grid-symbolic` (`theme/icons`, put in hicolor by install.sh; `desktop/kickoff-icon.sh`
  sets Kickoff's `icon` over plasmashell's scripting, from plasma-settings.sh): nine 5 px squares 4 px
  apart, whole pixels at 32 px and half a pixel right of the middle (23 can't centre in 32), so with the
  pager drawing a pixel inside its cell the gaps come out 18 | 18 docked, 14 | 14 floating. No dash after
  "plasma" in the name: KIconLoader tries a name cut short at each dash in one theme before the next one,
  and Breeze has `plasma-symbolic` (`QT_QPA_PLATFORM=offscreen kiconfinder6 NAME` shows what a name finds).
  Preview: `QT_PLUGIN_PATH=$(tools/patch-dev.sh kickoff)
  SHELL_PACKAGE=~/.cache/plasma-glass/dev/b/plasma-desktop/desktoppackage tools/preview/panel.sh`, with the
  icon in this account's ~/.local/share/icons and the start menu's `icon` in its copy of your layout;
  `check-patches.sh` compiles the patched main.qml.
- **Clicks press on the liquid** (2026-10-22, the user: "add the fluid effect when clicking on the menu
  items. have the effect like a push down on the floating element"). KWin does it without the apps:
  `slotMouseChanged` (EffectsHandler::mouseChanged, emitted on every button change, no polling needed)
  takes a left press, finds the topmost window that takes input under it in the stacking order
  (`Window::hitTest`, as KWin's own `InputRedirection::findToplevel` picks where a click goes: a
  click-through window doesn't count. With the window's frame geometry instead, no click pressed while
  Spectacle recorded a region (2026-10-24, the user: "when recording with spectacle clicks don't trigger
  the liquid glass wave effect"): it keeps a full-screen layer-shell overlay with an empty input region on
  every screen for the recording's dashed outline; checked in panel.sh's session with a real recording:
  pipewire and wireplumber started before the preview's KWin, `spectacle -R r -b -o FILE`, the region
  dragged with fakeinput and taken on release, `useReleaseToCapture=true`), and if that's a Liquid Glass
  surface (no KWin border radius; corners cut off its blur region, or a dock) and the press is on
  its blur region, records where in the glass and when (`BlurEffectData::click`, monotonic s, the clock
  `m_frameTime` comes from); the release sets `up`. blur() runs the liquid for a window with a Stir
  client, or a click, or liquid still settling (`runLiquid` takes the client as a pointer now, null for
  plasmashell's windows: no busy pushes, no breeze and no momentum for them, or every popup's slide-in
  and the panel's docking would slosh it). The press is fluid.frag's second Gaussian (`click`, beside the
  busy `press`), `clickWidth` px (24) wide, eased in and out with sin² over the time a wave that wide takes
  to pass (clamped 0.04-0.5 s) and held between, at `click` x 0.8 c² clickWidth, the busy press's pressure
  (it would press down by 0.8 x its width). The waves then run until settled, as the pushes'. On thin glass
  the shore and the sponge are narrowed (`shoreIn` at most 0.12 of the short side, `rimWidth` 0.5 of it - 2,
  both as they were from 69 px up, KRunner folded): with the 32 px sponge and 8 px shore a 46 px panel was all
  sponge and shore, and a click's waves died where they started. What shows: the dark glass bends what's
  behind by the waves' lean through the bevel's refraction (6 px on the panel after the thin-glass cap, 9
  elsewhere), clear at frost 1 (the user's) at 24 px; at 14 px a press was a barely visible dimple. Liquid
  Glass Light at the user's frost 6 blurs away what a narrow wave bends (a 14 px press changed nothing by
  more than 12 levels), so there it's the foil, which lights at crests normalized by a fresh push's crest
  (0.8 x the push width / 1.19: 41 px at the user's width 61, which left a click's crests at a quarter):
  a window only clicks stir normalizes by a third of the press's depth instead. Then it shows as soft
  patches of colour running out from the click, as KRunner's busy waves do there. Tuning: two sliders
  (Clicks: press, width). Dragging (the user, the same day: "clicking, then dragging behaves like pushing a
  finger through the liquid"): while the button is held, every pointer move adds a sample to `click.path`
  (the event's own time, libinput's, from the effect's `InputEventSpy`; place in the glass from its top left
  as pressed; the last 0.5 s), and each of the liquid's steps puts the press where the pointer was `lag` s
  before that step's middle, between the samples either side. Smoother (2026-10-24, the user: it was "like a
  series of clicks along the path", wanted "a continuous drag"): the steps run up to the frame's target
  pageflip time, past the newest event, and the press used to wait there for the next event and then jump,
  every frame (in the preview it stood still on 2 steps in 3 and jumped ~10 px in one; a re-run of the
  shallow water on those paths left separate dimples at a 1300 px/s drag's head), and its samples were
  stamped when KWin handled them, so a batch handled after a busy frame jumped at once. `lag` rises at once
  to 2 ms past how far a frame's steps run beyond the newest event and falls back at 2% of real time, so the
  press keeps to the path the events drew: its speed varies about as much as the preview's fake input's
  (8-16 ms apart). First measured as the button goes down, before any motion, it also allows for one report
  interval (`m_motionInterval`, a moving average of the gaps in all the pointer's motion): without that a
  drag's first events came later than the lag allowed, and the press held and jumped a few times as it
  started (a 4000 px/s step in a 1300 px/s drag; 1560 at most with it, and no still step once it moves).
  Real mice stamp evenly, so on screen it trails the cursor by a report interval and 2 ms at most.
  The dent kept trailing, though (the user: "make wave keep up with the pointer location better"): a pressure
  digs its dent only as fast as the liquid flows away, about 30 ms at their wave speed 305 px/s, so a press
  faster than the waves left it behind (probed in the preview's real liquid: deepest 27-32 px behind at
  ~720 px/s, 54-61 px at ~1600, never half as deep as at rest past ~1300). A dragged press is now a finger
  too (fluid.frag, `clickFinger`): under it the surface is pushed down to the press's resting dent with a
  4 ms time constant (`s_clickFinger`), never lifted, weighted g^3 (firmest at its middle; weighted g, a
  fast drag left a ripple per step in the trench behind). It fades in from 0.5 to 1.5 x the wave speed (the
  press's speed over 20 ms), since slower the pressure keeps up (0-3 px behind) and the finger halved the
  ring a plain click sends off as it's pressed. With it the dent's front edge stays 0-5 px ahead of the
  press at 690-1950 px/s (at rest ~12), full depth to 0.75 of it. The numpy model used to work this out is
  `tools/liquid/` (the user: "add the numpy testing setup to the kit"): `liquid.sh check` fails on each of
  the dropped variants (no finger, g weighting, the finger on for a still press), and `compare` on a
  `record.sh` log agreed with the real liquid to 0.8% of its spread.
  Then (the user, with a recording on Liquid Glass Light: "when moving fast now i'm seeing big rings at the
  stopping points instead of wakes"): a press faster than the waves sends a ring off as it stops whatever
  presses it (13 px high 70 px ahead after 600 px at 1500 px/s, against a plain click's 1.8; the waves it sent
  off as it stopped share a centre), but the finger had dimmed the wake that shows through the frost by a
  third at 1500 px/s and to 0.13 at 4000 (from 0.22 with the pressure alone), since it took away the liquid
  the pressure would have pushed into the wake. Smoothing the press's stops made the ring bigger (it
  overshoots and pushes more), and easing the pressure off while the finger leads lost the wake. Now the
  finger pushes the liquid aside: each cell works out what the finger pushes down there from its height as
  the step began (`pushedAt`, the dent as deep as at the press's centre), and cells in a ring two press widths
  round it (0.6 wide) add up all of it (the cells within 1.75 widths, at most 24 a side) and take it in.
  Through the frost the wake is 0.80 at 1500 px/s and 0.71 at 4000 (the model), the stop ring 13.2 and 7.9 px
  (13.7 and 6.8 before); the dent still keeps up, and the model matches the real liquid to 1.4%. After 20 ms with no event, a sample where the pointer stood is put in
  8 ms before the next, so the press doesn't creep across the pause. A
  press moving faster than the waves (667 px/s against the user's 305) trails a Mach-like wake; on the
  46 px panel it hits the rims at once and runs along as plane waves, visible where it crosses an edge
  behind; through Kickoff the light foil draws a streak of colour along the path. `DRAGS="X1 Y1 X2 Y2 MS"`
  in panel.sh (8 ms fakeinput steps). Then (the user: "add momentum to the windows when they slide up"): every
  Liquid Glass surface runs the liquid's followers each frame now (blur() calls `runLiquid` for all of them;
  calm, it returns at once), with KRunner's momentum: a popup sliding in (the slidingpopups effect moves it
  by `data`'s translation, which the blur shape takes) sloshes as it stops, and so do notifications, a
  tooltip moving between tasks and the panel docking. Kickoff over ColorfulCups with the user's tuning
  (momentum 2, sloshSpeed 1800, sloshDamping 6): Liquid Glass Light changed 20-50k px for 1.5 s after the
  slide, a band of foil light rolling across; the dark glass 1-3k px, at the edges behind. With slosh damping
  6 s the liquid runs 15 s after each move (3 x sloshDamping, capped). `POPUP_AT="S S"` in panel.sh opens and
  closes the popup mid-recording. Preview: `CLICKS="X Y, X Y" CLICK_HOLD=ms tools/preview/panel.sh OUT.mp4`
  (fakeinput presses while recording; `DOCK=1`, `POPUP=kickoff` first); the pointer shows in
  `CaptureArea`'s frames, so a frame difference lights up at the cursor, not only the waves.
- **The glass is a KWin plugin of its own** (2026-10-22, the user: relogging for every KWin change "is a
  massive time sink"; a KWin restart can't keep the apps: Firefox, Electron and GTK apps can't reconnect to
  a new compositor, and plasmashell and KRunner didn't either). KWin 6.7 loads effects from
  `kwin/effects/plugins` under Qt's library paths (only `/usr/lib64/qt6/plugins` for the session's KWin, no
  QT_PLUGIN_PATH) and loads and unloads them over D-Bus (`/Effects` `loadEffect`, `unloadEffect`,
  `isEffectLoaded`), and installs every header the blur needs (`/usr/include/kwin`, CMake `KWin::kwin`;
  only xcb had to be linked besides). So `kwin-effect/` is the patched blur (class `LiquidGlassEffect`,
  config class `LiquidGlassConfig`, still reading `[Effect-blur]`; logging category
  `kwin_effect_liquidglass`), and the KWin patch went back to Window Behavior's tabs. Traps on the way:
  KPluginMetaData takes an effect's name from its file's name (a metadata `Id` that differs only earns a
  warning), and Qt's plugin loader resolves links to the real file and keeps every library it has loaded
  (QLibraryStore by canonical path), so the same file never loads new code and a uniquely named file gets
  that name as the effect's. Hence each build is `<id>/liquidglass.so` and KWin's folder holds a link,
  `liquidglass.so`, to the one in use. Its shaders are its own resources under `:/plasma-glass/<id>/`: the
  built-in blur's and an earlier build's (still loaded) sit at `:/effects/blur/`, and `#include "sdf.glsl"`
  still finds KWin's `:/opengl/`. `supported()` checks `QCoreApplication::applicationVersion()` (KAboutData's
  `KWIN_VERSION_STRING`) against the version it was built for, so a stale build after a KWin update is
  skipped, not loaded into a different layout; Portage's hook (`/etc/portage/env/kde-plasma/kwin`
  `post_pkg_postinst`, sourced for KWin's merges) builds it again. A swap: unload liquidglass (or the
  built-in blur), load liquidglass from the link; clients' blur comes back by itself (KWindowEffects
  re-requests it when the blur manager global returns; KRunner's glass came out pixel-identical), but a
  Stir client (KRunner) is forgotten until it calls again (it does as it shows). Each swap leaves the old
  library mapped until KWin's next start. Same pixels as the built-in (KRunner, waves off: 0 px), same cost
  (KRunner busy over a panning wallpaper on the UHD 770: 5.09 ms GPU a frame against 5.16, both 13-16% of
  a core). Also found: the built-in effects live in the `kwin_wayland` executable, not libkwin, and libkwin
  came out byte-identical across builds that only changed the blur, so Portage left its inode in place
  (the running KWin mapped the "new" file); KConfig's `kconfig_add_kcfg_files` is a macro that sets
  `sources`, so a list of that name vanishes; moc doesn't track Q_PLUGIN_METADATA's json through
  KWIN_EFFECT_FACTORY (a new build id rebuilds everything anyway); and `pgrep -f` matched the sampler's own
  shell (match `/proc/PID/exe`).
- **KWin crashed at every logout** (Remember Window Positions' final save from a workspace already
  gone) until kde-fixes' `kwin-unload-scripts-before-workspace.patch`; preview KWins crashed the same way
  at their end.
- **The dark Liquid Glass bevel is drawn by KWin's blur** (`kwin-liquid-glass.patch`: the bevel pass in
  `plugins/blur/blur.cpp`, `shaders/onscreen_bevel.frag`), since only KWin has what's behind the glass;
  KRunner's shaders only see its own content. The glass is the blur region's bounding box, with each
  corner rounded as far as the frame's mask leaves it out of the region (read off its area; 26 px,
  generate.py R, on popups); a shape with no corner left out gets no bevel unless it's a panel (below),
  nor does a window with a title bar (it has KWin's own border radius). Within 24 px of the edge the glass rounds off like a quarter circle (tilt 1 at the
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
  overrides it. The liquid in KRunner's glass (above) leans the glass too: its surface's downhill slope,
  over a fresh wave's steepest (0.5), adds to the bevel's lean, so the bend and the colours' parting follow
  from one lean per pixel; a fresh wave's steepest slope leans as far as the bevel's edge at `[Ripple]
  amplitude` 1. A wave parts the colours a little
  more than the bevel, 3 px each way where it leans fully against the bevel's 2 (2026-10-14: "a tiny bit
  more aberration on the wave"): the split adds the waves' own lean, up to 1, times the difference
  (`[Ripple] aberration`; `KWIN_LIQUID_GLASS_RIPPLE=scale[,dispersion]` overrides both, scale 0 for no
  waves). How clear the glass is
  follows the bevel's lean, and under a wave its lean or its height (up or down), whichever is more: by
  the lean alone the glass frosted over again at each crest, which is flat (the user didn't like it).
  KWin keeps repainting while the liquid moves, whatever KRunner draws. The colours part only in the
  sharp samples: on the frost it doesn't show, and the blur's 8 samples three times over cost twice as
  much once the waves spread the per-pixel path over most of the window. With the knocks, in the preview
  (UHD 770 through Mesa, KRunner busy at 744x346, scale 1) KWin's GPU time was 1.12-1.20 ms a frame with the bevel and
  frost 2 and 1.96-1.98 with the slow, wide waves, eight knocks' at once (1.78-1.80 with a knock every
  1.8 s; at 180 px/s and 14 px 1.66-1.69, six at once, and 1.56-1.59 while they lasted 4.8 s, four at
  once, all once that many lived; with single waves 1.49-1.52; at frost 3, 1.25 and 1.57-1.62; with all
  27 samples, 1.40 and 2.12-2.15); with the wallpaper scrolling and
  KRunner idle it went from 2.04 (no bevel, strength 15) to 2.25-2.28 (bevel, strength 4). Over a smooth
  wallpaper (Next) it hardly shows: tuned on ColorfulCups and a scrolling image of code.
- **The liquid and the dark glass are tunable live** (2026-10-14, the user asked for a settings menu to
  fiddle with damping, aberration, strike location, speed, amplitude and width).
  `~/.config/plasma-glassrc` holds them: `[Ripple]` is the liquid's, which KWin reads itself
  (`loadLiquidGlassSettings`, again on every change through KDirWatch) and takes at its next step, so a
  change applies to the waves under way; KRunner only reads `side` and `position` (`View::liquidGlass`,
  numbers as numbers), to say where the pushes land. (With the knocks, KRunner read them all and each knock
  carried its wave's settings to KWin.) `[Glass]` is KWin's (frost, bevel), read again on every change
  too; `KWIN_LIQUID_GLASS_*` still win over the file, so the preview's before/after recordings work as
  before. The tuning window (`desktop/plasma-glass-tune.qml`, `qml6 -a widget`; install.sh installs it as
  `plasma-glass-tune` with a launcher) writes through QtCore's `Settings` (QSettings' INI, which KConfig
  reads, but neither takes comments after a value), at most every 0.1 s with `setValue()` and `sync()`:
  the declared properties write only 0.5 s after the last change, so a drag only arrived when it paused.
  A heartbeat, `[Ripple] tuning` (s since the epoch, 5 s ahead, every 2 s), keeps KRunner busy, so the
  liquid stirred, and open when it loses the focus (`View::tuning`); a crash lets it run out. KRunner reads
  the file again before closing on focus loss, in case the heartbeat has only just come. Sliders snap to
  their step in code: Breeze draws a tick for each step. Checked live in the preview (2026-10-14), the
  tuning window beside KRunner and its sliders dragged with fakeinput. The preview copies
  `plasma-glassrc` into its config, like your KDE files; keys only the knocks used (`widening`,
  `lifetime`, `ringing`, `edgeFade`, `standoff`, `packet`, `frontNoise`, `[Light] layer`) are ignored now.
- **More natural waves** (2026-10-14, the user: "would look more natural with some noise / more waves
  summed together", workshopped as four prototypes, then all four kept as settings for the knocks: chop,
  small plane waves across the glass; packet, two more profiles per knock; front noise, crests that
  wandered along their length; jitter). The liquid has interference, reflections and spreading of its
  own; of the four, jitter carries over to the pushes, chop became the breeze (`chop`, `chopScale`, the
  same keys and defaults), and packet and front noise went with the knocks.
- **The liquid has momentum** (2026-10-14, the user: "trigger waves when moving around the element and
  it opening and closing, like the liquid inside has momentum"; `[Ripple] momentum`, 1, 0 for none). Since
  2026-10-16 KWin works it out from the window's own geometry (above): the glass's centre's acceleration,
  through the followers, pushes the liquid the other way, so dragging KRunner sloshes it (it piles up
  against the trailing side, then rocks back and forth) and so does the dropdown unfolding (the centre
  moves; folding no longer does since 2026-10-30, below). Before, KRunner sampled its own place and height (`View::floatingMoved`,
  `floatingPosition()`) and a swing detector turned changes of speed into knocks off the wall that pushed
  into the liquid. What it found still holds for anything that differentiates a dragged window's place:
  frame-to-frame speed flickered with the pointer's 60 Hz steps against 120 Hz frames (a start made three
  small waves), acceleration's sign flipped with that noise, and over 60 ms a steady 1900 px/s drag still
  wobbled 500 px/s. The followers smooth that out, and the liquid itself doesn't care about the noise that's
  left: a jerk that averages out moves it little.
- **Liquid Glass Light's waves go beneath the frost** (2026-10-14: "the light version with frosted
  glass, the wave beneath the frosting", with a settings panel and the diffraction's etch size as a
  setting). KWin treats `liquid-glass-light` as Liquid Glass too: its own frost (`[Light] frost`, 5; it
  had KWin's own blur strength, 15 by default, before) and the bevel pass with `[Light]`'s bevel, off by
  default (the light style looks flat). While the liquid moves, `shaders/underlay.frag` runs between
  the background's copy and the first downsample: what's behind, seen from further in where a wave leans
  (`refraction`, 16 px x lean²), plus light where the waves crest in shards of colour, the Voronoi cells
  of a jittered grid `etch` px across (32), fixed to the window, each its own hue and sparkle
  (`diffraction` 1.2, `saturation` 0.8). The blur's passes frost that instead of the
  plain copy, and the waves don't lean the glass on top. Under the frost the shards' size decides what
  shows: at 12 px they blur into a near-white haze, at 32 they show as soft patches of colour, at 72 as
  big blobs. The first defaults (frost 7, refraction 12, diffraction 0.8, etch 28) were too faint
  under the light glass's 62% white tint. In the preview (UHD 770, 744x346) KWin takes 2.69-2.73 ms a
  frame on light glass with the waves, 1.26 without them; the foil costs nothing measurable (2.72 ms
  without it), the full-size underlay pass and the heavier frost do. KRunner could also draw the foil on
  top of the glass, crisp (`[Light] layer` top or both, which the user asked for on 2026-10-14), until the
  liquid: KRunner can't see a liquid only KWin has.
- **The foil lights at the sloshing's crests too** (2026-10-16, the user: "momentum waves on the light
  mode version don't seem to be rendering the diffraction pattern"). It lit where `wave.z` crests, the
  ripples' height only, and a window's moves go mostly into the swell (`s_swellMomentum` 30 against the
  ripples' 0.15), which reached the surface's slope but not its height. surface.frag now passes the
  swell's height in `w` (the dark bevel reads only `xyz`) over the crest of a slosh from rim to rim of
  the glass (√(w·h)) whose slope just leans it fully (lean x slope = `s_liquidSteep`), and underlay.frag
  adds it to the ripples' crest. Over the glass's size first (lean left out): with the user's tuning
  (momentum 2, sloshSpeed 1800, amplitude 2) a Meta+drag's sloshes crested at 0.3-0.4, faint patches;
  with the lean in, 0.7-1, as bright as the busy pushes' foil. Read the waves texture back (a scratch
  `glReadPixels` per frame into raw files) to measure such things; it slows KWin's frames.
- **Liquid Glass Dark Frost** (2026-10-30, the user: "create a darkmode version that uses the behind frost
  diffraction grains"): Light's glass in the dark, a third style beside the two. generate.py's
  `liquid-glass-dark-frost` follows the colour scheme as the dark style does (no colours file; its global
  theme sets Breeze Dark), with a deeper tint (`FILL_TRANSLUCENT` 0.50 against the dark's 0.40, so light text
  reads over the heavier frost) and rims and glow kept fairly even, as Light's are, so it looks flat. In
  KWin it's a frosted style as Light is: `FrostedGlass` (bevel, frost, underlay) for each, read from
  `[Light]` and `[DarkFrost]` with the same keys, and `m_frosted` points at the one in use (none on the
  dark glass). Its defaults are Light's but `saturation` 1. In the preview over the user's Orbit wallpapers
  (Tarantula, Rho), KRunner busy: through the dark tint, diffraction 0.6-0.8 lit faint, muddy patches and
  1.2 a clear sheen of colour; at 1.2, saturation 0.8 came out a little paler and greyer than 1 (a modest
  difference). A drag through Kickoff leaves a trail of coloured shards. plasma-glass-mode takes
  `dark-frost`, and the dark one last picked there (or by install.sh's style) becomes KDE's
  `DefaultDarkLookAndFeel`, which the toggle and KDE's own Dark Mode switch go back to from light.
- **KRunner dropped frames as its dropdown unfolded** (2026-10-30, the user: "on the laptop there are some
  dropped frames on fold and unfold"). Measured in the preview on the laptop itself (its CPU; the main box hides
  it) with `frametimes.sh`: KWin rendered every frame in 2.5-5 ms and skipped no vblanks; KRunner took two 50 ms
  steps at the start of every unfold (176->251->315 px) and was smooth after. It wasn't the day's changes (the
  KRunner from before them did the same), the glass (built-in blur alike) or the search service's inference on
  the shared GPU (queries every 0.2 s through its D-Bus `Match` changed nothing). A profile of KRunner's main
  thread (`perf record --call-graph dwarf -t`) put it in making the rows: the list's height animates from 0, so
  ListView made the rows each step uncovered, two or three at a time over OutQuart's fast start. milou's
  ResultsView now has `cacheBuffer: 10000`, so every row is made as the results come, while the window is still
  folded: no dropped frame in an unfold since, and the unfold doesn't start any later. Found on the way, both
  KRunner's main thread: KSvg's `FrameSvg::mask()` (Plasma's window takes its blur region from it on every
  resize: a render of the whole mask frame per step, about a quarter of the thread's time) and, 600 ms after
  the last step, KSvg saving the last frame to its disk cache as PNG (37-44 ms). Building the region from the
  corners of a 128 px mask instead (disconnecting PlasmaWindow's handler from DialogBackground's `maskChanged`)
  gave the very same regions at all 51 sizes compared, but measured no fewer drops, even with KRunner on two
  E-cores, so it wasn't shipped; it's the next thing to try if folds still drop. The first fold after KRunner
  starts takes one 30-40 ms step. The preview's own bug, fixed: KWin started before session.sh set
  `XDG_CURRENT_DESKTOP=KDE`, so its KService cache listed different mimeapps.list files from the apps' and the
  two rebuilt the shared cache for each other about once a second, with two fsyncs on KWin's main thread (30-45 ms
  on the laptop's disk), which first looked like KRunner waiting 60-70 ms in its swaps for frame callbacks.
- **KRunner's dropdown stuttered on the main box** (2026-10-30, the user: "the unfold feels like it stutters"
  on the 60 Hz screen, where KRunner floats, "while the laptop is now very smooth"). On desktop NVIDIA QtWayland
  up to 6.11 turns threaded GL off (resizing froze Qt Quick there: QTBUG-95817), so KRunner gets the basic loop, which
  draws on the GUI thread, and QtWayland makes each swap wait for KWin's frame callback (`waitForFrameSync`, for
  a swap interval of 1): 15-16 ms of every 60 Hz frame in which the GUI thread can't take in the size it asked for
  or step animations, which the basic loop drives from a 16 ms timer anyway. Reproduced in the preview at 60 Hz
  with `QSG_RENDER_LOOP=basic` (Mesa, the preview's renderer, with NVIDIA's loop forced): the dropdown moved
  every 33-50 ms, and against OutQuart over 350 ms its steps came 13.8 ms off their frames' times on average (sd;
  worst 47), against 1.0 (worst 2.8) on the threaded loop. KRunner first got its own fix, on the basic loop only
  (e43a474): swap interval 0 (frames still come as KWin asks for them; 2.5 ms sd, worst 10.7, no step late) and an
  animation driver that stepped once per frame at the frame's time rounded to the screen's refresh period, as the
  threaded loop's does (1.3 ms sd, worst 3.7, no step late, not even the first fold's). The same evening kde-fixes
  backported Qt 6.12's fix for QTBUG-95817 (`qtbase-wayland-nvidia-threaded-resize.patch`): Qt picks the threaded
  loop on NVIDIA again, for plasmashell's popups and every other Qt Quick app too, so KRunner's fix came out (the
  user, trying it on the 60 Hz screen: "it feels smooth"). In the preview on the NVIDIA card the threaded loop's
  steps came 0.8-1.5 ms off the curve, none late but one in the first fold after KRunner started (35 ms). With a
  stock Qt 6.11 the stutter is back. The timing error: from each logged height, where along the easing curve
  that frame was, against when it came (`frametimes.sh` logs; a frame that repeats a step shows as a 33 ms gap, a
  late one as a time off the curve).
- **KRunner flickered after its dropdown folded** (2026-10-30, the user, with a screencast: "i'm seeing a
  flickering after krunner dropdown collapse", and that it predated Dark Frost). The momentum (above) took
  the fold as the glass's centre rising ~300 px and stopping, and pushed the liquid that was left in the
  70 px bar as hard as an unfold; across 70 px the swell rocks every 0.4 s at the user's `sloshSpeed` 350,
  and their uneven floor (0.8) scattered it into choppy waves that bent what's behind for the 1.2 s their
  `sloshDamping` took. Reproduced in the preview by typing "f" and Backspace with fakeinput while recording
  (`INPUT`, the user's plasma-glassrc), measured as the mean frame-to-frame change inside the bar: with
  momentum 0 the bar was still at once. Two changes, each half the fix alone: a shrinking glass moves its
  liquid only by the move both its edges share (`carried()` in runLiquid; growing still counts the centre,
  so the unfold sloshes as before), and the swell fades faster across thin glass, each way by the glass's
  long side over its length that way (the slosh across the bar left from an unfold 1.25 s earlier rocked on
  too). Over the 3 s after a fold, the dark glass went from 1.55 mean change (124 of 174 frames over 0.5)
  to 0.013 (none), Dark Frost from 0.48 (89) to 0.007. Separately, the window dropped 4 px about 80 ms
  after the fold seemed to end: the results' 4 px top margin stayed until the view hid, and OutQuart's
  last pixel takes that long; it now folds away with the results' last 4 px (RunCommand.qml).
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
- **KRunner doesn't render for its busy feedback** (2026-10-16, the user: still "lagging a bit" on the
  laptop on battery, power-saver, CPUs near 1 GHz). With the knocks, the busy ripple's `FrameAnimation`
  kept Qt's render loop going on dark glass, where KWin drew the waves, so KRunner rendered the same frame
  at the screen's rate and KWin blurred each one anew for as long as waves lived (13.5 s with the laptop's
  `[Ripple] lifetime`); a `Timer` that woke only for the next knock took it from 755 frames and 1,020 ms of
  CPU to 207 and 830 ms over a typed "kernel config laptop" (main box; KWin's frames were the same). Since
  the liquid, KRunner only calls KWin when it gets busy or done or the push's place changes. Measured with
  `QSG_RENDER_TIMING=1` (render-loop lines in app.log), KWin's `KWIN_LOG_PERFORMANCE_DATA=1` (written to
  KWin's working directory), and keys typed by fakeinput as `HOVER_INPUT` after `krunner.sh OUT " "` (an
  empty query means the default one). The laptop's own `plasma-glassrc` is heavy: `[Glass] frost=15`,
  `bevelWidth=60`. The preview runs there too (configs copied as on the main box; no EGL override, it has
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
- **Liquid Glass Light came out dark after a switch from dark** (2026-10-16): a KSvg bug, its
  stylesheet cache, fixed in kde-fixes (`ksvg-stylesheet-cache.patch`, notes in its AGENTS.md).
  `SWITCH="FROM TO" tools/preview/krunner.sh OUT.png "q"` switches global themes mid-run to reproduce
  such things (`OUT-before.png`, then `OUT.png`). To see what an app draws without KWin's blur, grab its
  window in the app (`QQuickWindow::grabWindow()`).
- **KRunner ran in background.slice** (2026-10-16, the dropdown at about 20 fps on the laptop in
  power-saver): Plasma's `plasma-krunner.service` puts it at a third of the apps' CPU weight. kde-fixes'
  install-user.sh moves it to session.slice (it was plasma-glass's `plasma-glass-priority.conf` drop-in
  until 2026-10-17). The preview never shows such things (no load there), and profiling the preview at
  150 fps capture (unfold.sh) misleads: the capture itself is the biggest load, and its stalls were its
  own. The laptop's own `plasma-glassrc` is heavy: `[Glass] frost=15`, `bevelWidth=60`.
- **The dropdown's momentum waves restarted and rode down the glass** (2026-10-16, the user: "the wave
  animation seems to be somehow restarting every frame", then "the wave is translating down the element
  as the window opens"). Counted with `dbus-monitor --session "type=method_call,member=Knock"` in the real
  session: 11 bottom-edge knocks in 6 s, most at full strength, in threes 0.3-0.9 s apart. Results arrive
  in batches, so opening unfolded, stopped and unfolded again, and each stop knocked; and a knock while the
  dropdown still grew rode down with it, since a bottom wave was placed from the current bottom edge. A
  settling timer and knocks that kept the window's size fixed it then; the liquid has neither problem: its
  cells stay put in the glass (from its top left), and a dropdown that unfolds in batches sloshes it a
  little at each, as it would a real one. The preview never showed it: its query arrives at once and
  unfolds once.
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
- **A System Settings result in KRunner only made the open System Settings demand attention**
  (2026-10-17): KWin's activation tokens, fixed in kde-fixes (`kwin-activation-token-serial.patch`). The
  preview never showed it (no other window there asks for a token as it gets the focus back).
- **Shortcuts in settings search** (2026-10-21, the user: "include the shortcut menu in the index.
  There's already a search function in the shortcut settings menu you could probably leverage"):
  - The global ones change with what's installed and running, so the service lists them itself at start
    (a thread of its own, `settings_loop`) from kglobalaccel, inside KWin: `/kglobalaccel allComponents`,
    then each component's `allShortcutInfos`, `a(ssssssaiai)` = action id, action name, component id,
    component name, context, context name, keys, default keys. Keys are Qt key codes with modifier bits
    (one per key sequence, 0 for none); `settings_index.py` takes Qt's names for them from qtbase's
    `qkeysequence.cpp` (`keys` in the list), so they read as in System Settings ("Meta+PgUp", "Volume
    Up"). Common Actions are KStandardShortcut's table (kconfig's source, the Linux side of its `#if`s),
    changed keys in kdeglobals `[Shortcuts]`. Each Match checks the keys again (at most every 2 s, ~1 ms)
    and wakes `settings_loop` when actions came or went. At login the service can start before KWin:
    it tries again each minute until kglobalaccel answers.
  - Embedded as "title: Maximize Window | text: keyboard shortcut, Window Management[, the app's
    GenericName or Comment from its .desktop file]", not where the page puts it: of four forms tried on
    19 queries, that one put 13 in the top 3 ("Shortcuts › Spectacle. Keyboard shortcut": 11; it missed
    "screenshot of a region" → Capture Rectangular Region). "lock screen" still doesn't find Lock Session,
    nor does the page's own search.
  - The page (kcm_keys): component names are the page's, not kglobalaccel's (KWin is "Window
    Management", plasmashell "Plasma Workspace": basemodel.cpp), an app's launch action (id `_launch`)
    is named after the app ("Konsole") but shows as "Launch", and a component id can hold spaces ("KDE
    Keyboard Layout Switcher"), which matters because systemsettings splits `--args` at spaces. So the
    patch takes the longest run of leading words that is a component id, puts the rest in the search
    field (the filter matches action and component names and keys), and opens the action named so, or
    the launch action when the rest is the component's name. When the page is already open, systemsettings
    sends the arguments as `activationRequested` (forwarded to the KQuickConfigModule), which stock ignores.
  - Tested with `tools/preview/settings.sh` and `SYSTEMSETTINGS_ENV="QT_PLUGIN_PATH=$(tools/patch-dev.sh
    kcm-keys)"`, also with `ARGS2` (the open page) and a component registered by hand on the preview's
    bus with spaces in its id (`dbus-send ... org.kde.KGlobalAccel.doRegister array:string:ID,ACTION,NAME,ACTION`).
  - In the preview, KRunner's first query starts the search service (D-Bus activation), which answers
    before its options are loaded: type another letter once it's up (`HOVER_INPUT` with `key CODE
    down/up`). A space and backspace don't re-query (KRunner skips an unchanged query). The preview's copy
    embeds new labels without storing them (`EMBEDSEARCH_NO_REINDEX`), each run.
  - KRunner's own Global Shortcuts runner lists the same actions when KWin's global shortcuts are on (it
    runs them); these open their settings. For "capture rectangular region" KRunner's first result is
    Spectacle's own desktop action (it takes the screenshot).
  - The user's report the same evening ("selecting a different shortcut from krunner does not update the
    term in the shortcut menu searchbox"): the picks that didn't were the page's own UI labels ("Cancel
    Export"), which settings_index.py had put under "Shortcuts › Common Actions" (the page's list section
    names were taken for sections), so they looked like shortcuts, and they open the page without
    arguments, which the patch then ignored. Now list section names aren't sections, and an activation
    without arguments clears the search. Real shortcuts updated it every time (checked on the user's
    desktop with gdb: breakpoints on `KAbstractConfigModule::activationRequested` and
    `QQuickTextInput::setText`, both exported). Attach with `handle SIGINT stop print nopass`: without it
    the interrupt that ends `timeout -s INT gdb` reaches the app on detach and quits it (it did once).
- **A shortcut's key beside its name** (2026-10-23, the user: "show the current main keybind for
  shortcut dropdown items. Also right justify", then, seeing the key at the right and the path after the
  name: "put the shortcut on the left and the path on the right"): settings search's shortcut results and
  KRunner's Global Shortcuts runner (plasma-desktop's `runners/keys`, patched) send the key after a tab in
  the subtext ("Shortcuts › Window Management\tMeta+Q"; D-Bus runners have no other field for it), and
  milou's ResultDelegate shows what follows the tab right after the name on every row (the name elides to
  keep room for it) and the rest, where it is, right-aligned like a file's folder (on the selected row, as
  other subtexts). Every System Settings result of the service has the tab, with no key after it when
  there is none, so all their locations sit at the right (the user, on an unbound shortcut whose location
  stayed after the name: "this should be right justified"). Stock milou would show the tab as a space.
  - There is no main key to ask for: the Shortcuts page lists an action's keys as a set, kglobalaccel's
    `allShortcutInfos` returns them in no particular order ("Alt+F1, Meta" for the launcher), and
    `kglobalshortcutsrc` holds them sorted by key code. So both pick one the same way: a key set by hand
    (not among the defaults: the user's Meta+Q for Close Window, Meta+1 for Desktop 1) before the defaults,
    a key every keyboard has before a lone media or launch key (Qt's codes above `Key_Direction_R`: Lock
    Session is Meta+L, not Screensaver), then by key code (Meta before Alt+F1, Alt+Tab before Meta+Tab).
    Common Actions keep KStandardShortcut's order in the last step, its main key first. An action with no
    key shows none; the stock runner showed its default keys then.
  - Preview: `SHORTCUTS=1` (the preview's KWin then serves kglobalaccel, with a copy of your
    `kglobalshortcutsrc`) and `KRUNNER_ENV="QT_PLUGIN_PATH=$(tools/patch-dev.sh kcm-keys)"` for the dev
    runner. The Global Shortcuts runner shows only a few of its matches (for "switch to desktop", the
    unbound Desktops 8 and 9); "close window" has a keyed row in both groups. For record.sh, the search
    service's results come after the window is measured (it starts cold on the first query, even when
    started over D-Bus a second before KRunner), so record with `PAD=160` and crop to the window after.
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
  copy between the GPUs at about 7 GB/s. kde-fixes' Qt fixes are installed here (since 2026-10-12, as
  plasma-glass's Qt patches then), so KRunner renders on the GPU with no drop-in. KWin got no real-time priority until 2026-10-13 ("Failed to gain
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
- **Cross-GPU blur darkening** (main box, 2026-10-12): with KWin on the iGPU, its blur darkened what's
  behind a window on DP-4 (the NVIDIA card's screen); not reproducible after a reboot, and KWin
  composites on the NVIDIA card since 2026-10-13, so the watch has ended. `tools/screenprobe/screen.sh
  glass` (a 190 grey square with an empty `PlasmaCore.Window` on it, the style's glass and blur, placed
  by a KWin script) measured the glass at 129 (dark) and 225 (light) on DP-4 and DP-1 alike. A KWin bug
  report draft was written (not filed; kept outside the repo); don't file it unless this comes back. The
  resize glitches' root causes, once open items here, were Qt's and are fixed in kde-fixes.
- **Remember password:** the laptop's ksshaskpass passphrase wasn't saved to KWallet yet (tick it
  at login).
