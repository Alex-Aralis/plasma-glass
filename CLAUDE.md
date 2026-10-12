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
| `tools/preview/` | screenshots on a virtual KWin display: `krunner.sh`, `dialog.sh`, `elements.sh` |

## Dev loops

- **Style:** edit `generate.py`, then `tools/preview/krunner.sh /tmp/k.png "query"` (or
  `STYLE=repo-light`). Apply with `./install.sh --no-search --no-settings`, which regenerates the SVGs,
  drops Plasma's cached renders and reapplies.
- **Patches:** `tools/patch-dev.sh setup`, edit under `~/.cache/plasma-glass/dev/b/<pkg>/`, then
  `refresh` and `check`, then `sudo tools/patch-dev.sh install`. After the build, run
  `systemctl --user restart plasma-plasmashell.service` (notifications) and `kquitapp6 krunner`.
  milou rebuilds in about 2 min, plasma-workspace in about 25 min on the laptop.
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
- **Plasma caches style renders** in `~/.cache/plasma_theme_<id>.kcache`. Switch to another style,
  delete the cache, then switch back.
- **KRunner is a layer-shell surface.** KWin can't move it, and Wayland clients never learn their
  position. KRunner places itself with layer margins (`View::applyFloatingMargins`, keys
  `FloatingTop`/`FloatingCenterX`). Test dialogs from `qml6` can't place themselves either (KWin
  reserves plasma-shell), so `dialog.sh` shows them without top/left frame edges.
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
- **Shell:** `grep` may be ugrep (`$` mid-pattern differs). Never nest a here-doc whose body
  contains its own delimiter.

## Machines

- **Laptop (t14):** i5-1245U, Iris Xe (Gen12.3), `intel-compute-runtime:legacy` (works on Gen12
  despite Gentoo's note). GPU f16 runs about 2,000 tokens/s for indexing and about 40 ms per query.
- **Main box:** Gentoo, Intel iGPU (drives KDE) plus NVIDIA. `install-system.sh` picks the runtime
  from `lspci`. OpenVINO's GPU device only uses Intel.

## Open items

- **KRunner drag-to-move** (commit 48f263a) has only been syntax- and load-checked, never dragged
  for real. If it jitters, the cause is likely that the margin update lags the pointer. Track the
  press-time position plus the total offset instead of incremental steps.
- **Remember password:** the laptop's ksshaskpass passphrase wasn't saved to KWallet yet (tick it
  at login).
