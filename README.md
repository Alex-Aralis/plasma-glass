# plasma-glass

A Liquid Glass look and semantic file search for KDE Plasma 6 on Gentoo, with the KRunner and
notification cruft trimmed.

- **Semantic search in KRunner.** [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2)
  (text encoder, 270M) runs on the Intel iGPU through OpenVINO in float16. Your documents are indexed
  in the background, and results appear in KRunner (Alt+Space), about 0.2 s per query. Searching
  finds files by meaning, not just by name.
- **Liquid Glass Plasma Style.** Translucent popups over KWin's blur: 18 px corners, a light rim along
  the top, a soft shadow, glassy search fields, list highlights and scrollbars. Everything else
  falls back to Breeze, and colours follow your colour scheme.
- **Trimmed KRunner and notifications.** KRunner floats where you drag it (by the glass rim or any
  empty spot) and remembers the spot. It is wider, and types straight onto the glass in larger text, with no input box, like Spotlight. It uses
  compact section headers and has no help, settings, pin or clear buttons. Notification popups lose
  their settings and close buttons and the countdown bar, and show a pointer when clicking them
  opens something.

## Install

On a Gentoo box with Plasma 6 and an Intel iGPU, clone the repo and run both parts:

```sh
git clone git@github.com:Alex-Aralis/plasma-glass.git && cd plasma-glass
./install.sh                # as your user: search service, KRunner plugin, style, settings
sudo ./install-system.sh    # as root: Intel GPU runtime, Portage patches, rebuilds plasma-workspace + milou
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

Override with `--runtime=legacy|current|skip`. A discrete NVIDIA GPU is fine: OpenVINO's GPU device
uses only the Intel iGPU. Rebuilding plasma-workspace is a long compile. Use `--no-rebuild` to only
install the patches and let them land with your next update.

Both scripts are safe to re-run. `./install.sh --help` lists options for skipping parts.

## Using and tuning the search

- **Settings:** `~/.config/embedsearch/config.toml` controls the folders, file types, number of
  results and reindex interval. The defaults are `~/Projects`, `~/Documents`, `~/Downloads` and
  `~/Desktop`, with md, txt, org, rst, tex, pdf, docx, odt and html files. Restart with
  `systemctl --user restart embedsearch` after editing.
- **Terminal:** `embedsearch search "query"` searches from the command line, `embedsearch status`
  shows what's indexed, and `journalctl --user -fu embedsearch` shows indexing progress.
- **Updates:** new and changed files are picked up every 15 minutes. Identical text is only embedded
  once, and renamed copies show once in results.
- **Results:** KRunner always shows the top five. Similarity scores can't reliably separate nonsense
  from real queries, so there's no cutoff.

## What gets changed

| Where | What |
|---|---|
| `~/.local/share/embedsearch/` | search service, its venv, the OpenVINO model, the index |
| `~/.config/embedsearch/config.toml` | search settings |
| `~/.local/share/krunner/dbusplugins/`, `~/.local/share/dbus-1/services/`, `~/.config/systemd/user/` | KRunner plugin and the service that runs it |
| `~/.local/share/plasma/desktoptheme/liquid-glass/` | the Plasma Style (`generate.py` draws it) |
| `krunnerrc`, `kdeglobals` | settings from [`desktop/plasma-settings.sh`](desktop/plasma-settings.sh) |
| `/etc/portage/patches/kde-plasma/{plasma-workspace,milou}/` | the QML patches (root) |

`plasma-settings.sh` sets a KDE restriction to hide KRunner's settings button. As a side effect,
that also hides the KRunner page in System Settings. Delete `kcm_krunnersettings` from
`~/.config/kdeglobals` to get it back.

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

The patches were made against Plasma 6.7.5. Portage re-applies them whenever plasma-workspace or
milou is rebuilt. If a future Plasma version changes the patched lines, that build stops at the
patch step until the patch is refreshed.

- `plasma-workspace-tweaks.patch`
  - KRunner: wider (40 grid units), 1.3x search text, borderless search field, no pin or clear
    button, no scrollbars; the results area unfolds smoothly as results arrive (the window follows)
  - KRunner position when floating: drag it by the glass rim or any empty spot; the spot is saved as
    `krunnerrc [General] FloatingTop` (top edge as a fraction of the screen height; stock is 1/3) and
    `FloatingCenterX` (horizontal centre as a fraction of the width; stock is 0.5). No "Ctrl+F"
    tooltip on the search field
  - notification popups: more padding, wider gaps between icons and text, no settings or close
    buttons (the history keeps them), header padding fixed, pointer cursor when the popup is clickable. Popups still close on click, timeout,
    middle-click or swipe
- `milou-section-headers.patch`: KRunner result categories become small headers above each group
  instead of a 10-grid-unit column beside every row

Before changing a patch, run `tools/check-patches.sh` (10-30 s). It applies the patches to the
source of your installed versions and loads the patched QML under Qt, with stubs for KRunner's and
the notification applet's internal modules. That catches errors which only show when KRunner or
plasmashell starts, such as assigning to a grouped property. It also syntax-checks the patched
C++. `install-system.sh` runs it before installing anything.

## Uninstall

```sh
./uninstall.sh    # user part; prints the root commands that undo the system part
```
