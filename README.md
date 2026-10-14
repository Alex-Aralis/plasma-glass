# plasma-glass

A Liquid Glass look and semantic file search for KDE Plasma 6 on Gentoo, with the KRunner and
notification cruft trimmed.

- **Semantic search in KRunner.** [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2)
  (text encoder, 270M) runs on the Intel iGPU through OpenVINO in float16. Your documents are indexed
  in the background, and results appear in KRunner (Meta+Space), about 0.2 s per query. Searching
  finds files by meaning, not just by name.
- **Liquid Glass Plasma Style.** Translucent popups over KWin's blur: 18 px corners, a light rim along
  the top, a soft shadow, glassy search fields, list highlights and scrollbars, and quiet header
  bands in applet popups. Everything else
  falls back to Breeze, and colours follow your colour scheme. With the KWin patch, the dark style's
  glass is frosted lightly and rounds off at the edge like a lens: what's behind bends there and parts
  a little in colour.
- **Trimmed KRunner and notifications.** KRunner opens with Meta+Space (Alt+F2 still works) and floats where you drag it (by the glass rim, or anywhere
  with Meta held, as with other windows) and remembers the spot. It is wider, and types straight onto the glass in larger text, with no input box, like Spotlight. It uses
  compact section headers and has no help, settings, pin or clear buttons. Notification popups lose
  their settings and close buttons and the countdown bar, and show a pointer when clicking them
  opens something.

## Install

On a Gentoo box with Plasma 6 and an Intel iGPU, clone the repo and run both parts:

```sh
git clone git@github.com:Alex-Aralis/plasma-glass.git && cd plasma-glass
./install.sh                # as your user: search service, KRunner plugin, style, settings
sudo ./install-system.sh    # as root: Intel GPU runtime, Portage patches, rebuilds the patched packages
systemctl --user restart plasma-plasmashell.service embedsearch; kquitapp6 krunner
```

`install.sh` exports the model once. It builds a temporary PyTorch environment, downloads the model
(about 1.5 GB), converts it, checks the result against PyTorch and then deletes the PyTorch
environment. That takes a few minutes. After that, the service only needs OpenVINO (about 300 MB of
Python packages plus a 540 MB model).

`install-system.sh` picks the Intel compute runtime from your iGPU:

| iGPU | Runtime |
|---|---|
| Iris Xe and UHD (Tiger Lake to Raptor Lake, and older) | `intel-compute-runtime:legacy` (tested on Alder Lake) |
| Meteor Lake / Core Ultra, Arc and newer | `intel-compute-runtime` |

Override with `--runtime=legacy|current|skip`. A discrete NVIDIA GPU is fine: OpenVINO lists it
as a GPU too (through NVIDIA's OpenCL driver), but the search service picks the Intel one, and falls
back to the CPU if the GPU can't run the model. Rebuilding plasma-workspace, qtbase and qtdeclarative
takes a while (only packages whose patch is new or changed are rebuilt). Use `--no-rebuild` to only install the
patches and let them land with your next update, or `--no-qt` to leave Qt alone.

Both scripts are safe to re-run. `./install.sh --help` lists options for skipping parts.

## Using and tuning the search

- **Settings:** `~/.config/embedsearch/config.toml` controls the folders, file types, number of
  results and reindex interval. The defaults are `~/Projects`, `~/Documents`, `~/Downloads` and
  `~/Desktop`, with md, txt, org, rst, tex, pdf, docx, odt and html files. Restart with
  `systemctl --user restart embedsearch` after editing.
- **Terminal:** `embedsearch search "query"` searches from the command line, `embedsearch status`
  shows what's indexed, and `journalctl --user -fu embedsearch` shows indexing progress.
- **Updates:** new and changed files are picked up every 15 minutes, or right away with the "Index"
  launcher (KRunner or the app menu), which ends with a notification saying what it indexed. While
  it indexes, KRunner shows a progress bar. Identical text is only embedded once, and renamed copies
  show once in results.
- **Results:** KRunner always shows the top five. Similarity scores can't reliably separate nonsense
  from real queries, so there's no cutoff.

## What gets changed

| Where | What |
|---|---|
| `~/.local/share/embedsearch/` | search service, its venv, the OpenVINO model, the index |
| `~/.config/embedsearch/config.toml` | search settings |
| `~/intel/openvino_telemetry` | `0`: opts out of OpenVINO's usage reporting to Google Analytics (sent on every import otherwise); an existing file is left alone |
| `~/.local/share/krunner/dbusplugins/`, `~/.local/share/dbus-1/services/`, `~/.config/systemd/user/` | KRunner plugin and the service that runs it |
| `~/.local/share/plasma/desktoptheme/liquid-glass/` | the Plasma Style (`generate.py` draws it) |
| `krunnerrc`, `kdeglobals`, `kglobalshortcutsrc` | settings from [`desktop/plasma-settings.sh`](desktop/plasma-settings.sh) |
| `~/.config/systemd/user/plasma-krunner.service.d/plasma-glass-software-render.conf` | only when KWin composites on an NVIDIA GPU and the Qt patches aren't installed: KRunner renders in software (otherwise a resizing KRunner shows its old frame shifted for a frame, so the results' unfold jumps); without the qtbase patch, Qt also skips viewporter/fractional scaling |
| `/etc/portage/patches/kde-plasma/{plasma-workspace,milou}/`, `/etc/portage/patches/dev-qt/{qtbase,qtdeclarative}/` | the patches (root) |

`plasma-settings.sh` sets a KDE restriction to hide KRunner's settings button. As a side effect,
that also hides the KRunner page in System Settings. Delete `kcm_krunnersettings` from
`~/.config/kdeglobals` to get it back. It also gives KRunner Meta+Space in place of Alt+Space, unless
another shortcut already uses Meta+Space (then it says so and leaves KRunner's keys alone);
`uninstall.sh` puts Alt+Space back.

To look at notification popups, open **Test Notifications** from KRunner or the start menu, or pin
it to the panel. It sends a clickable one, a long one that scrolls, one with an image and a critical
one. Right-click it to send a single kind, or run `plasma-glass-test-notifications [kind]`.

## Tweaking the style

The style is drawn by [`theme/liquid-glass/generate.py`](theme/liquid-glass/generate.py). Corner
radius, padding, glass opacity, rim brightness and shadow are constants at the top. After editing,
re-run `./install.sh --no-search --no-settings`. That regenerates the SVGs, clears Plasma's cache of
the old ones and reapplies the style.

Plasma sizes each piece by its bounding box, so the generator builds everything from fills inside
exact tile rectangles. Strokes would make the box half a pixel bigger and leave visible gaps.

To see edits before installing them, [`tools/preview/`](tools/preview/README.md) screenshots KRunner
or a test dialog with the repo's version of the style. It runs on a virtual display, so nothing
appears on your screen.

```sh
tools/preview/krunner.sh /tmp/krunner.png "some query"
```

## Patches

The patches were made against Plasma 6.7.5 and Qt 6.11.2. Portage re-applies them whenever
plasma-workspace, milou, kwin, qtbase or qtdeclarative is rebuilt. If a future version changes the patched lines, that
build stops at the patch step until the patch is refreshed.

- `plasma-workspace-tweaks.patch`
  - KRunner: wider (40 grid units), 1.6x search text with a larger search icon, borderless search
    field, no pin or clear button, no scrollbars; the results area unfolds smoothly as results arrive
    and folds away when they go (the window follows); while a search takes more than half a second, a
    knock on the glass beside the search field sends a wave across it every 1.2 s instead of a spinner, a
    crest with a ringing train behind, as an impulse makes on water (on dark glass, with the KWin patch,
    the waves bend what's behind the glass and KRunner draws nothing of them; on Liquid Glass Light they
    show as a foil sheen; with software rendering, a band of light sweeps across instead; none with
    animations turned off); a
    thin line under the search field, as in Spotlight; results that don't fit run on to the glass's
    bottom edge; while the semantic search service indexes new or changed files, "Indexing…" and a
    progress bar under the search field (from the service's `local.embedsearch` `/indexer` D-Bus
    object, property `Progress`: 0-1 while indexing, -1 otherwise)
  - KRunner position when floating: drag it by the glass rim, or anywhere with KWin's window-move
    modifier held (Meta unless changed in kwinrc), like other windows; the window follows the
    pointer's relative motion, so it stays under the pointer, onto other monitors too (it moves there
    with its query and results). The spot is saved as
    `krunnerrc [General] FloatingTop` (top edge as a fraction of the screen height; stock is 1/3),
    `FloatingCenterX` (horizontal centre as a fraction of the width; stock is 0.5) and
    `FloatingScreen` (the monitor it was dragged to, e.g. `DP-4`; it opens there while that monitor is
    connected, otherwise on the active one like stock). No "Ctrl+F"
    tooltip on the search field
  - notification popups: more padding, wider gaps between icons and text, summary and body text
    about 1.2x larger, the app name on the glass (no header band), no settings or close buttons (the
    history keeps them), no coloured stripe on critical ones, header padding fixed, pointer cursor
    when the popup is clickable. Popups still close on click, timeout,
    middle-click or swipe
- `milou-section-headers.patch`: KRunner result categories become small headers above each group
  instead of a 10-grid-unit column beside every row; result text 1.2x
- `kwin-fixes.patch` (kde-plasma/kwin; a new KWin runs from the next login)
  - the dark Liquid Glass style's glass, as in [liquidglass](https://github.com/ybouane/liquidglass):
    frosted lightly all over (blur strength 2 of 15, never more than your own setting), so what's
    behind shows through as soft shapes; and within 24 px of the edge a bevel that bends that view (seen
    from up to 9 px further in at the very edge), turns sharp toward the rim and splits it in colour by
    up to 2 px each way. KRunner's busy ripple bends what's behind the glass the same way as its waves
    run, ringing behind each crest, clear across each wave and on into the bevel at the far edge, its
    colours parting a little more than the bevel's (KRunner tells KWin about each knock over D-Bus).
    Only while that style is selected (it follows `plasmarc`, no relogin), on Plasma's own surfaces
    (KRunner, popups, notifications, panels with rounded corners), not on windows with title bars. In
    KWin's environment, `KWIN_LIQUID_GLASS_FROST=strength`,
    `KWIN_LIQUID_GLASS_BEVEL=width,refraction,dispersion,sharpness` and
    `KWIN_LIQUID_GLASS_RIPPLE=scale,dispersion` override them (2; 24,9,2,1; 1,3, scale 0 for no waves)
  - frame callbacks go out after each screen's composite, not only when KWin is about to sleep, so a
    window on one screen doesn't wait for another screen's composite (KRunner's ripple missed frames
    on the 240 Hz screen while another one animated)
  - with KWin on one GPU and a screen on another, the rendering GPU copies frames over itself when the
    screen's GPU can't, instead of the CPU (`KWIN_DRM_NO_RENDER_GPU_COPY=1` turns it off), with the CPU
    cache flushed first, which otherwise left horizontal strips missing from the cursor
  - no crash at every logout: scripts are unloaded before the workspace goes away (Remember Window
    Positions saved its state from a workspace that was already gone)
- `qtbase-wayland.patch` (dev-qt/qtbase, every Qt app): Qt's Wayland client sends a window's new
  viewport size (`wp_viewporter`, used with fractional scaling) together with the buffer drawn for it.
  It sent it as soon as the window resized, so the compositor showed the previous frame stretched to
  the new size for a frame (KRunner's text flickered while its results unfolded). Not fixed upstream
  as of Qt's dev branch (2026-10). Also, a window resized while a frame is being drawn on Qt Quick's
  render thread takes the new size once that frame is done: at high refresh rates the frame in flight
  sometimes got a buffer of the new size and showed shifted (KRunner's search box jumping down for a
  frame while typing during the unfold)
- `qtdeclarative-quick.patch` (dev-qt/qtdeclarative, every Qt Quick app):
  - the GUI-thread render loop, which Qt uses whenever the GPU is NVIDIA, takes the window's size
    after polishing instead of before. A window sized to its content resizes while polishing, so the
    frame after each resize was drawn at the old size into the new, larger or smaller buffer and
    showed shifted (KRunner jumped and left ghosts while its results unfolded)
  - animations follow the refresh rate of the screen a window is on. Qt Quick took the primary
    screen's (on Wayland the first output Qt sees, here a 60 Hz one), then took a 240 Hz screen's
    faster frames for broken vsync and animated from a 16 ms timer: KRunner, Plasma's popups and every
    Qt Quick app animated at 60 fps on 165 and 240 Hz monitors

To change a patch, use `tools/patch-dev.sh`. `setup` unpacks clean and patched copies of the sources
for your installed versions. Edit the files, then `refresh` writes the patch files, `check` validates
them and `sudo tools/patch-dev.sh install` rebuilds what changed. `tools/patch-dev.sh qt` builds
just the patched Qt libraries (Wayland client, Qt Quick) and prints the environment that runs an
app on them.
Before any rebuild, run `tools/check-patches.sh`
(10-30 s). It applies the patches to the
source of your installed versions and loads the patched QML under Qt, with stubs for KRunner's and
the notification applet's internal modules. That catches errors which only show when KRunner or
plasmashell starts, such as assigning to a grouped property. It also syntax-checks the patched
C++. `install-system.sh` runs it before installing anything.

## Uninstall

```sh
./uninstall.sh    # user part; prints the root commands that undo the system part
```
