# plasma-glass: notes for development

Liquid Glass Plasma Styles, semantic KRunner search (EmbeddingGemma 2 on the Intel iGPU via OpenVINO)
and Portage patches for KRunner, notification popups and milou. Gentoo, Plasma 6.7.5, Wayland. User
docs are in README.md; this file covers how to work on it.

## Layout

| Path | What |
|---|---|
| `search/embedsearch.py` | search service: indexer, KRunner D-Bus runner (`local.embedsearch`), CLI. Installed copy: `~/.local/share/embedsearch/` (service `embedsearch.service`) |
| `search/export_model.py` | one-time PyTorch to OpenVINO export with a parity check (run by install.sh in a throwaway venv) |
| `theme/liquid-glass/generate.py` | draws both styles (`liquid-glass`, `liquid-glass-light`) into `~/.local/share/plasma/desktoptheme/` |
| `patches/kde-plasma/{plasma-workspace,milou}/*.patch` | Portage user patches, one per package |
| `desktop/` | KRunner plugin, systemd and D-Bus files, `plasma-settings.sh` (krunnerrc, kdeglobals, plasmanotifyrc) |
| `tools/patch-dev.sh` | patch workflow: setup, edit, check, refresh, install |
| `tools/check-patches.sh` | patches apply; patched QML loads under qml6 with stubs; patched KRunner C++ syntax-checks |
| `tools/preview/` | screenshots on a virtual KWin display: `krunner.sh`, `dialog.sh`, `popup.sh` (a real plasmashell tray popup), `elements.sh`; `fakeinput.c` for pointer input |
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
- **Shell:** `grep` may be ugrep (`$` mid-pattern differs). Never nest a here-doc whose body
  contains its own delimiter.

## Machines

- **Laptop (t14):** i5-1245U, Iris Xe (Gen12.3), `intel-compute-runtime:legacy` (works on Gen12
  despite Gentoo's note). GPU f16 runs about 2,000 tokens/s for indexing and about 40 ms per query.
- **Main box:** i9-14900K, UHD 770 (Raptor Lake-S GT1, Gen12, drives KDE) plus an RTX 2080 Ti.
  `install-system.sh` picks `:legacy` from `lspci`. OpenVINO lists the NVIDIA card as a GPU too
  (through `nvidia.icd`; it's plain `GPU` when the Intel runtime is missing), and it can't compile
  the f16 model. `embedsearch.intel_gpu()` picks the device with `vendor=0x8086`. The UHD 770 is
  slow (32 EUs vs the laptop's 96): GPU f16 indexes 4.3 chunks/s with 39 ms queries, the CPU (f32)
  8.9 chunks/s with 14 ms queries. `MAKEOPTS="-j32 -l32"`; plasma-workspace rebuilds in about 6 min.

## Open items

- **KRunner drag-to-move** was rewritten to follow relative pointer motion and measured on the
  virtual display (exact final position, one even step per frame, clamped at the screen edge). It
  works by hand (rim). The 12 px rim is the only empty spot (the query field spans the full width,
  the results list takes presses), so Meta+drag (KWin's move modifier from kwinrc) works anywhere,
  through an overlay MouseArea that refuses presses without the modifier. KWin passes Meta+click
  to layer-shell windows. Measured on the virtual display; needs a real-hand test after the rebuild.
- **Remember password:** the laptop's ksshaskpass passphrase wasn't saved to KWallet yet (tick it
  at login).
