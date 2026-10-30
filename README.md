# plasma-glass

A Liquid Glass look and semantic file search for KDE Plasma 6 on Gentoo, with the KRunner and
notification cruft trimmed.

- **Semantic search in KRunner.** [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2)
  (text encoder, 270M) runs on the Intel iGPU through OpenVINO in float16. Your documents are indexed
  in the background, and results appear in KRunner (Meta+Space), about 0.2 s per query. Searching
  finds files by meaning, and every file by its name and folders, fuzzily ("pragconv" finds
  `pragmatic-convalescence.md`, "t14 readme" `hosts/t14/README.md`). It also finds the options inside
  System Settings pages, which KRunner alone only knows by page name: "focus stealing" opens Window
  Behavior on its Focus tab, "tap to click" the Touchpad page. Keyboard shortcuts too, with their keys:
  "maximize window" shows Meta+Up and opens the Shortcuts page searching for it, with its keys open
  to change.
- **Liquid Glass Plasma Style.** Translucent popups over KWin's blur: 18 px corners, a light rim along
  the top, a soft shadow, glassy search fields, list highlights and scrollbars, and quiet header
  bands in applet popups. The panel is the same glass, floating or docked: a rounded bar with 16 px
  corners while it floats, and flush against the screen's edge once a maximized window docks it, glass
  still (the style turns off Plasma's adaptive transparency, which made a docked panel opaque). Docked,
  it casts no shadow, and its popups keep floating clear of it with all their corners rounded, as they do
  from the floating panel (both with the patches). Everything else falls back to Breeze, and colours follow your colour scheme. With the Liquid Glass effect (a KWin plugin, see Patches), the dark style's
  glass is frosted lightly and rounds off at the edge like a lens: what's behind bends there and parts
  a little in colour. KRunner's glass holds a liquid, simulated: it sloshes as you drag KRunner or its
  dropdown opens, and while a search runs its rim pushes into it, sending waves across that bend what's
  behind. The light style's glass is frosted more, and the waves run beneath the frost, lit in shards of
  colour as off an etched diffraction foil; Dark Frost is that glass in the dark, the shards a sheen of
  colour under smoky frost. A click presses down on the liquid of the glass it lands on,
  the panel, a popup or KRunner, like a finger on a floating pane: a dimple under the pointer while the
  button is held, and rings that run out as it's pressed and let go. Drag with the button held and the
  finger goes through the liquid, leaving a wake behind it. And every glass surface's liquid has momentum:
  a popup sliding up sloshes it as it stops, as dragging KRunner does. The panel's glass rounds off at its edges too, but not where
  it meets the screen's edge: docked, only its top edge bends what's behind.
- **Trimmed KRunner and notifications.** KRunner opens with Meta+Space (Alt+F2 still works) and floats where you drag it (by the glass rim, or anywhere
  with Meta held, as with other windows) and remembers the spot. It is wider, and types straight onto the glass in larger text, with no input box, like Spotlight. It uses
  compact section headers and has no help, settings, pin or clear buttons. Files show where they are on
  every row, right-aligned, not just on the selected one; hovering one unrolls that into its full folder
  (panning along when it's too long). Notification popups lead with the notification's own icon or
  picture, big, with the title and body in larger text beside it and the app's small icon and name
  across from the title. Their text sits on frosted glass;
  a screenshot or buttons below it sit on the clearer glass. They lose their settings and close
  buttons and the countdown bar, and show a pointer when clicking them opens something.

## Install

On a Gentoo box with Plasma 6 and an Intel iGPU, clone the repo and run both parts:

```sh
git clone git@github.com:Alex-Aralis/plasma-glass.git && cd plasma-glass
./install.sh                # as your user: search service, KRunner plugin, style, settings
sudo ./install-system.sh    # as root: Intel GPU runtime, Portage patches, rebuilds the patched packages
systemctl --user restart plasma-plasmashell.service embedsearch; kquitapp6 krunner
```

Install [kde-fixes](https://github.com/Alex-Aralis/kde-fixes) too: fixes for bugs in KWin, Plasma, KSvg
and Qt that plasma-glass carried until 2026-10-17 (KWin's crash at every logout, frame pacing with several
screens, apps launched from KRunner that only flashed in the task manager, colours after a Dark Mode
switch, Qt's resize glitches and 60 fps animations on faster screens, KRunner's low priority). They
aren't plasma-glass's, so they have a repo of their own; with an older plasma-glass installed, run this
`install-system.sh` before kde-fixes' `install.sh`.

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
back to the CPU if the GPU can't run the model. Rebuilding plasma-workspace and kwin takes a while (only
packages whose patch is new or changed are rebuilt). Use `--no-rebuild` to only install the patches and
let them land with your next update.

Both scripts are safe to re-run. `./install.sh --help` lists options for skipping parts.

## Using and tuning the search

- **Settings:** `~/.config/embedsearch/config.toml` controls the folders, file types, number of
  results and reindex interval. The defaults are `~/Projects`, `~/Documents`, `~/Downloads`,
  `~/Desktop` and `/etc`, with md, txt, org, rst, tex, pdf, docx, odt and html files indexed by their
  text and all other files by name (`all_file_names = false` for only those). In `text_folders`
  (`/etc`) every text file's text is indexed, whatever its name; binary files, certificates and keys,
  and files only root can read are found by name. Restart with
  `systemctl --user restart embedsearch` after editing.
- **System Settings options:** `search/settings-index.json` lists about 1300 option, group and tab
  labels from the 63 System Settings pages shown here, with the page (and, for Window Behavior, the tab)
  each is on. They show under KRunner's "System Settings" results: up to three, those holding every
  word of the query first, then any close in meaning (`settings_results`, `settings_min_score` in the
  config). They come above the files when one holds every word of the query, the query says
  "settings" ("settings focus stealing"), or one is closer in meaning than any file. The selected one
  shows where it is at the row's right end ("Window Behavior › Focus"), as files do. Choosing one
  opens its page. Pages a KDE restriction hides are left out. The list is built
  from the installed packages' sources in /var/cache/distfiles by `search/settings_index.py`; re-run it
  after a Plasma upgrade. Only new labels are embedded again. Pages one machine lacks keep their
  entries from the last list, so it covers every machine it was built on.
- **Keyboard shortcuts:** every action on System Settings' Shortcuts page is an option too: the global
  shortcuts (KWin's, Spectacle's, each app's launch key, custom commands) as KDE's shortcut service
  (kglobalaccel) lists them, and Common Actions (Copy, Find, Zoom In...). Each shows the key it goes by
  now beside its name ("Maximize Window  Meta+Up"; of several, one you set before the defaults, then a key
  every keyboard has before a media or launch key: Lock Session is Meta+L, not Screensaver), and where it
  is at the row's right end when it's selected ("Shortcuts › Window Management"); any of its keys' names
  finds it ("volume up" finds Increase Volume). Choosing one opens the Shortcuts page with the action in its search field and
  its keys open to change (that needs the plasma-desktop patch; without it the page opens on the
  action's app). The service lists them when it starts and checks their keys as you type, at most every
  2 s, so a changed key shows at once and a new action is searchable within seconds.
- **Terminal:** `embedsearch search "query"` searches from the command line, `embedsearch settings
  "query"` searches the System Settings options, `embedsearch status`
  shows what's indexed, and `journalctl --user -fu embedsearch` shows indexing progress.
- **Updates:** new and changed files are picked up every 15 minutes, or right away with the "Index"
  launcher (KRunner or the app menu), which ends with a notification saying what it indexed. While
  it indexes, KRunner shows a progress bar and its busy waves run. Identical text is only embedded once, and renamed copies
  show once in results.
- **Results:** KRunner always shows the top five. Up to three files whose name and path hold every
  word of the query come first (at least one word in the name; a word can be a substring, or its
  letters in order from a word's start, as in fzf), then the closest by meaning. A word with slashes
  goes folder by folder: `02/020/030` puts files under `02/020-…/` first even when there's no `030`.
  Each result says where it is in short, keeping the folders that tell the results apart
  (`fso/…/drafts/02/020-morning-praxis` beside `fso/…/outlines/02`); hovering one shows its full path. Similarity scores
  can't reliably separate nonsense from real queries, so there's no cutoff.

## What gets changed

| Where | What |
|---|---|
| `~/.local/share/embedsearch/` | search service, its venv, the OpenVINO model, the index |
| `~/.config/embedsearch/config.toml` | search settings |
| `~/intel/openvino_telemetry` | `0`: opts out of OpenVINO's usage reporting to Google Analytics (sent on every import otherwise); an existing file is left alone |
| `~/.local/share/krunner/dbusplugins/`, `~/.local/share/dbus-1/services/`, `~/.config/systemd/user/` | KRunner plugin and the service that runs it |
| `~/.local/share/plasma/desktoptheme/liquid-glass{,-light,-dark-frost}/` | the Plasma Styles (`generate.py`, in the first, draws all three) |
| `~/.local/share/plasma-glass/`, `~/.local/bin/plasma-glass-tune`, `~/.local/share/applications/plasma-glass-tune.desktop` | Liquid Glass Tuning, which writes `~/.config/plasma-glassrc` (see [Tuning](#tuning-the-glass-and-krunners-liquid-live)) |
| `~/.local/bin/plasma-glass-mode`, `~/.local/share/applications/plasma-glass-mode.desktop` | Toggle Dark/Light Mode (below) |
| `~/.local/share/plasma/look-and-feel/plasma-glass.liquid-glass{,-light,-dark-frost}/`, `kdeglobals` `[KDE] DefaultDarkLookAndFeel`, `DefaultLightLookAndFeel` | the Liquid Glass global themes, and KDE's default dark and light ones |
| `krunnerrc`, `kdeglobals`, `kglobalshortcutsrc` | settings from [`desktop/plasma-settings.sh`](desktop/plasma-settings.sh) |
| `/etc/portage/patches/kde-plasma/{plasma-workspace,milou,kwin,plasma-desktop}/` | the patches (root): `plasma-workspace-tweaks.patch`, `milou-section-headers.patch`, `kwin-window-behavior-tabs.patch`, `plasma-desktop-tweaks.patch`, beside kde-fixes' |
| `/usr/lib64/qt6/plugins/kwin/effects/plugins/liquidglass.so`, `/usr/local/lib64/plasma-glass/`, `/usr/local/share/plasma-glass/`, `/etc/portage/env/kde-plasma/kwin` | the Liquid Glass effect: KWin's link to the build in use, the build, its source and tool (for Portage's hook), the hook (root) |
| `kwinrc` `[Plugins] blurEnabled`, `liquidglassEnabled`; `~/.local/bin/plasma-glass-reload-kwin` | the effect in place of the built-in blur; swaps a new build into the running KWin |

`plasma-settings.sh` sets a KDE restriction to hide KRunner's settings button. As a side effect,
that also hides the KRunner page in System Settings. Delete `kcm_krunnersettings` from
`~/.config/kdeglobals` to get it back. It also gives KRunner Meta+Space in place of Alt+Space, unless
another shortcut already uses Meta+Space (then it says so and leaves KRunner's keys alone);
`uninstall.sh` puts Alt+Space back.

To switch between dark and light, run `plasma-glass-mode` (or **Toggle Dark/Light Mode** from KRunner or
the start menu; `plasma-glass-mode dark`, `dark-frost` or `light` sets one, and the launcher's right-click
menu has all three). It applies the Liquid Glass, Liquid Glass Dark Frost or Liquid Glass Light global
theme: the Plasma Style (KWin's glass follows), Breeze Dark or Breeze Light colours, and icons to match.
They are also KDE's default dark and light global themes, so KDE's own Dark Mode switch (in the tray's
Brightness and Color, and in Quick Settings) does the same instead of putting the Plasma Style back to
Breeze. There are two dark ones: the one you last picked (with `plasma-glass-mode` or `install.sh
--dark`/`--dark-frost`) is the one the toggle and KDE's switch go back to from light. Give the launcher
a shortcut in System Settings > Keyboard > Shortcuts to toggle with a key.

To look at notification popups, open **Test Notifications** from KRunner or the start menu, or pin
it to the panel. It sends a clickable one, a long one that scrolls, one with an image and a critical
one. Right-click it to send a single kind, or run `plasma-glass-test-notifications [kind]`.

## Tweaking the style

The style is drawn by [`theme/liquid-glass/generate.py`](theme/liquid-glass/generate.py). Corner
radius, padding, glass opacity, rim brightness and shadow are constants at the top. After editing,
re-run `./install.sh --no-search --no-settings`. That regenerates the SVGs, clears Plasma's cache of
the old ones and reapplies the style.

The panel's frame takes the same glass with its own corner radius, shadow and margins (`PANEL_R`,
`PANEL_SHADOW`, `PANEL_THICK_MARGIN`). Floating, Plasma draws all of it; docked, it leaves out the edges
against the screen's.

Plasma sizes each piece by its bounding box, so the generator builds everything from fills inside
exact tile rectangles. Strokes would make the box half a pixel bigger and leave visible gaps.

To see edits before installing them, [`tools/preview/`](tools/preview/README.md) screenshots KRunner
or a test dialog with the repo's version of the style. It runs on a virtual display, so nothing
appears on your screen.

```sh
tools/preview/krunner.sh /tmp/krunner.png "some query"
tools/preview/panel.sh /tmp/panel.png            # your panel, floating; DOCK=1: docked by a maximized window
```

### Tuning the glass and KRunner's liquid, live

KRunner's glass holds a liquid (with the Liquid Glass effect): shallow water simulated on the GPU, in two layers,
since on real water long waves run faster than short ones. The ripples, short and slow, come from the
busy push: while a search runs (or the index builds), a stretch of the rim beside the search field pushes
into the liquid and eases back out, again and again, and a light breeze raises small waves all over. The
swell, long and fast, is the liquid's momentum: dragging KRunner, or its dropdown opening and closing,
sloshes it, since it lags behind as the glass speeds up and runs on as it stops. Waves reflect off the
liquid's edge (as much as you set), cross and interfere, and die down; KWin bends what's behind the glass
by them. The edge runs a little in from the rim in gentle bends and the floor is a little uneven (waves
run faster where it's deeper), so waves don't set out or come back ruler-straight.

"Liquid Glass Tuning" (`plasma-glass-tune`, in the start menu or KRunner) has a slider for each of the
liquid's settings, the dark glass's, Liquid Glass Light's and Dark Frost's: the ripples' speed, width, how often a
push comes, damping, how much the rim sends back, amplitude, colour split, the breeze and its gusts'
size, jitter; how the liquid is stirred (pushing the rim in, or pressing on the surface just inside it),
which side, where along it and how much of it pushes in as one; momentum, and the sloshing's speed and
damping; how hard and how wide a click presses; how far the shore bends and how uneven the floor is; the dark glass's frost, bevel width,
refraction, colour split and sharpness; and the light
glass's frost, the waves' refraction and diffraction beneath it, the diffraction foil's etch size and
saturation, and an optional bevel; and the same for Dark Frost. Changes apply as you drag. While the window is open, KRunner's
liquid is stirred all the time and KRunner stays open when you click elsewhere, so open KRunner
(Meta+Space) beside it and tune. Each row has a button back to its default, and "Reset All" resets
everything. It needs the patched KRunner (`plasma-workspace-tweaks.patch`) and the Liquid Glass effect.

The settings live in `~/.config/plasma-glassrc`, which you can also edit by hand (plain `key=value`
lines; the tuning window rewrites the file as you move its sliders):

| Group | Key | Default | What |
|---|---|---|---|
| `[Ripple]` | `speed` | 120 | px/s the ripples run at |
| | `width` | 21 | px, half the width of the wave a push makes |
| | `interval` | 1.2 | s from one push to the next |
| | `damping` | 36 | s for a ripple to fall to about a third of its height, on its own |
| | `reflection` | 0.3 | how much of a ripple the rim sends back (0-1; the rest soaks into it) |
| | `amplitude` | 1 | how far a wave's steepest slope leans the glass, against the bevel at its edge |
| | `aberration` | 3 | px the colours part each way where a wave leans fully |
| | `chop` | 0.3 | the breeze: gusts pressing on the surface while busy, raising small waves all over (0: none) |
| | `chopScale` | 40 | px, the gusts' size |
| | `jitter` | 0.6 | each push a little different in place, strength, length and timing (0-1) |
| | `stir` | push | `push`: a stretch of the rim pushes in and eases back; `press`: a press on the surface just inside it |
| | `side` | left | `left`, `right`, `top` or `bottom` |
| | `position` | 0.333 | how far along that side the pushes land once results show (beside the search field before) |
| | `strike` | 1 | px of the side that pushes in as one (the rest bows in less); wider starts a flatter front |
| | `momentum` | 1 | how much the glass moving or growing sloshes the liquid (0: none): KRunner dragged or its dropdown opening or closing, a popup sliding up, the panel docking; the ripples it stirs are as wide as `width` |
| | `sloshSpeed` | 900 | px/s the long waves run at: faster, and the liquid rocks back and forth quicker |
| | `sloshDamping` | 1.5 | s for the sloshing to fall to about a third |
| | `shore` | 8 | px the liquid's edge wanders either way, a little in from the rim (0: it follows the rim) |
| | `shoreScale` | 120 | px, how long the shore's bends are |
| | `floor` | 0.35 | how much deeper and shallower the liquid gets (0-0.8 of the average; 0: flat), bending waves as they cross |
| | `floorScale` | 220 | px, how long the floor's swells are |
| | `click` | 1 | how hard a click presses down on the liquid of the glass it lands on (the panel, its popups, KRunner) while the button is held (0: clicks don't) |
| | `clickWidth` | 24 | px, how wide the press is (the radius of a Gaussian) |
| `[Glass]` | `frost` | 2 | blur strength 1-15, never more than KWin's Blur setting |
| | `bevelWidth` | 24 | px |
| | `refraction` | 9 | px |
| | `dispersion` | 2 | px |
| | `sharpness` | 1 | 0-1 |
| `[Light]` | `frost` | 5 | blur strength 1-15 over the waves, never more than KWin's Blur setting |
| | `refraction` | 16 | px what's behind bends beneath the frost where a wave leans fully |
| | `diffraction` | 1.2 | how bright the foil's colours are where the waves crest |
| | `etch` | 32 | px, the size of the foil's shards of colour |
| | `saturation` | 0.8 | 0-1 |
| | `bevelWidth`, `bevelRefraction`, `bevelDispersion`, `bevelSharpness` | 24, 0, 0, 0 | a bevel as the dark glass's (off: flat) |
| `[DarkFrost]` | the same keys as `[Light]` | the same, but `saturation` 1 | Liquid Glass Dark Frost's glass |

Keys from before the liquid was simulated (`widening`, `lifetime`, `ringing`, `edgeFade`, `standoff`,
`packet`, `frontNoise`, `[Light] layer`) are ignored.

KWin's environment still overrides the glass for experiments (`KWIN_LIQUID_GLASS_*`, below).

## Patches

The patches were made against Plasma 6.7.5. Portage re-applies them whenever plasma-workspace, milou,
kwin or plasma-desktop is rebuilt, together with kde-fixes' patches for the same packages (they change other files). If a
future version changes the patched lines, that build stops at the patch step until the patch is
refreshed.

- `plasma-workspace-tweaks.patch`
  - KRunner: wider (40 grid units), 1.6x search text with a larger search icon, borderless search
    field, no pin or clear button, no scrollbars; the results area unfolds smoothly as results arrive
    and folds away when they go (the window follows); while a search takes more than half a second, the
    liquid in the glass is stirred instead of a spinner: KRunner tells KWin it's busy and where the
    pushes land (beside the search field), and KWin, with its patch, runs the liquid (KRunner draws
    nothing of it; with software rendering, a band of light sweeps across instead; no pushes with
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
  - the panel (plasmashell): docked, it casts no shadow, as if it were part of the screen's edge; floating,
    it keeps its shadow (it goes as the panel touches the edge and comes back as it leaves)
  - notification popups: no header row. A 48 px icon on the left: the notification's own icon or picture
    (avatars and photos get rounded corners), centred on the text beside it (or that text on the icon,
    when the icon is taller); with none, no icon, and the text starts at the left. An
    icon the icon theme doesn't have counts as none, instead of the theme's blank "unknown" page. The
    title (1.5x, 15 pt) runs the full width, its first line leaving room for the sender across from
    it: the app's small icon, then quietly the web page for a browser's notification
    (calendar.google.com) or else the app's name, and the time once the popup is a minute old. The body
    (1.3x, 13 pt) sits under the title; a body of more than three lines there goes below the cut
    instead, the full width, eight whole lines at most before it scrolls, through the whole section:
    from the cut down to the glass's bottom edge (or a shelf of buttons). Its scroll bar is in the
    glass's right margin, so the text keeps the same margin on both sides, and it shows only while the
    text scrolls (and for a moment after), or while the pointer is on it. Popups are 1.25x Plasma's
    width (445 px at scale 1), so lines keep their length. More padding. Content (a screenshot, a long
    body) sits below a cut 16 px under the text, 16 px further down. On the light glass the part below
    the cut is frosted less: the popup draws the style's glass itself, as it is above the cut and at
    half strength below (KWin's blur is the same). On the dark glass, where that left the parts too
    alike, the frosted parts get more frost instead, a white haze at 10% (over the whole popup when it
    has no cut). A very light shadow falls from the cut (black at 4% on the light glass, 11% on the
    dark, easing out over 10 px). Controls (buttons, a reply field, a transfer's progress) sit on a shelf
    set off from what's above them: under the text, below a cut on the glass frosted less; after
    content, on a frosted shelf at the bottom. Its edge is 12 px below what's above, and as far above
    the controls (20 px) as the glass's bottom edge is below them, so they sit in its middle.
    A screenshot shows as a rounded picture, 160 px tall, under the text (stock's blurred band slid up
    over the second line). No settings or close buttons (the history keeps them), no countdown bar,
    no coloured stripe on critical ones. The arrow over the popup, the pointing hand only over its
    buttons and links (a screenshot keeps Plasma's open hand, as it can be dragged out). Its text can't
    be selected (the history's still can). Paragraphs in the body are set apart by half a line, once
    kde-fixes keeps the blank line between them (stock's server folds it into a line break).
    Popups still close on click, timeout, middle-click or swipe;
    middle-click and click now work anywhere on them (stock lost the middle button to the body's
    scroll view, a Pane that takes every button, and nothing took clicks on the rim outside mainItem)
- `milou-section-headers.patch`: KRunner result categories become small headers above each group
  instead of a 10-grid-unit column beside every row; result text 1.2x; a shortcut's key beside its name
  on every row (a result's subtext after a tab: settings search's shortcuts and the Global Shortcuts
  runner's), the subtext before the tab (where it is, also with no key: every settings search result
  has the tab) at the row's right end, as a file's folder
- `kwin-window-behavior-tabs.patch` (kde-plasma/kwin; `kwin-liquid-glass.patch` until 2026-10-22, when the
  glass left it for the Liquid Glass effect, below): Window Behavior in System Settings opens on a tab given
  as an argument (`systemsettings kcm_kwinoptions --args focus`; also `titlebar-actions`, `window-actions`,
  `movement`, `advanced`), also when it's already open, so settings search lands on the option's tab
- `plasma-desktop-tweaks.patch` (kde-plasma/plasma-desktop; `plasma-desktop-shortcut-search.patch` until
  2026-10-22)
  - the panel: a floating panel that docks (a window touches it) keeps its popups floating, a gap from the
    panel with all their borders, as they are while it floats; stock attaches them to it, square on its side.
    A panel set not to float keeps Plasma's choice ("Floating applets" in its settings)
  - System Settings' Shortcuts page opens on an action: `systemsettings kcm_keys --args "kwin Maximize
    Window"` (the component's id, then the action's name) puts the name in the page's search field,
    selects the component and opens the action's keys, also when the page is already open. Stock takes
    only the component (and only when the page opens), so settings search's shortcut results land on the
    shortcut. An app's launch key is asked for by the app's name (`org.kde.konsole.desktop Konsole`), since
    the page shows it as "Launch". Opened again with no arguments (a result for the page itself), it
    clears its search
  - KRunner's Global Shortcuts runner shows the key an action goes by (chosen as settings search does)
    beside its name, instead of all its keys, in no order, on the selected row; an action with no key
    shows none (stock showed its default keys then)

### The Liquid Glass effect

`kwin-effect/` is KWin 6.7.5's blur effect with the glass in it, built as a KWin plugin of its own in place of
the built-in blur (kwinrc `[Plugins] blurEnabled=false`, `liquidglassEnabled=true`; it reads the blur's
settings, so System Settings' blur strength still applies). Being a plugin, a new version swaps into the
running KWin: `plasma-glass-reload-kwin` builds it, installs it (sudo) and has KWin load it in place of the old
one, in a second, with no relogin and no app closing (`tools/kwin-effect.sh status` says which build runs). It
only loads into the KWin version it was built against, so `install-system.sh` adds a Portage hook
(`/etc/portage/env/kde-plasma/kwin`) that builds it again whenever KWin is merged; if that build ever fails,
KWin runs with no blur until it's fixed (`tools/kwin-effect.sh disable` puts the built-in blur back). What it
draws:

The dark Liquid Glass style's glass, as in [liquidglass](https://github.com/ybouane/liquidglass):
frosted lightly all over (blur strength 2 of 15, never more than your own setting), so what's
behind shows through as soft shapes; and within 24 px of the edge a bevel that bends that view (seen
from up to 9 px further in at the very edge), turns sharp toward the rim and splits it in colour by
up to 2 px each way. KRunner's glass holds a liquid (it asks for one over D-Bus,
`org.kde.KWin.LiquidGlass.Stir`): shallow water simulated on the GPU, sloshing as the window moves
or grows and pushed while KRunner is busy, whose waves bend what's behind the glass the same way, the
glass clear where they run, their colours parting a little more than the bevel's (see
[Tuning](#tuning-the-glass-and-krunners-liquid-live)). Every glass surface gets the liquid where a
click lands on it (KWin watches the pointer's button; no app asks): it presses down there while the
button is held, follows the pointer while it's dragged, and lets go as the button comes up. Liquid Glass Light gets frosted glass too
(strength 5), flat by default, with the waves beneath the frost: what's behind bends under them, and
an etched diffraction foil lights up in shards of colour where they crest, all softened by the frost.
Liquid Glass Dark Frost gets the same glass under its dark tint, the foil's colours fully saturated
(against the dark, Light's 0.8 comes out a little paler and greyer). Only while one of those styles is
selected (it follows `plasmarc`, no relogin), on Plasma's own surfaces
(KRunner, popups, notifications, the panel), not on windows with title bars. The glass's corners
are read off each surface's shape, whatever their radius; where the glass meets the screen's edge (a
docked panel) it has no bevel, as it runs on past it; and on thin glass (the panel) the bevel is at
most 35% of its thickness, refracting proportionally less. In
KWin's environment, `KWIN_LIQUID_GLASS_FROST=strength`,
`KWIN_LIQUID_GLASS_BEVEL=width,refraction,dispersion,sharpness` and
`KWIN_LIQUID_GLASS_RIPPLE=scale,dispersion` override them (2; 24,9,2,1; 1,3, scale 0 for no waves)

The bug fixes these patches held until 2026-10-17 (KWin's frame pacing across screens, the render GPU's
copy for another GPU's screens, the crash at every logout, activation tokens; KSvg's colours after a style
switch; Qt's resize glitches and 60 fps animations; the notification body's cursor) are in
[kde-fixes](https://github.com/Alex-Aralis/kde-fixes), one patch per fix.

To change a patch, use `tools/patch-dev.sh`. `setup` unpacks clean and patched copies of the sources
for your installed versions. Edit the files, then `refresh` writes the patch files, `check` validates
them and `sudo tools/patch-dev.sh install` rebuilds what changed.
Before any rebuild, run `tools/check-patches.sh` (about 10 s). It applies the patches to the source of
your installed versions, alone and with the other user patches you have for the same packages
(kde-fixes'), and loads the patched QML under Qt, with stubs for KRunner's and
the notification applet's internal modules. That catches errors which only show when KRunner or
plasmashell starts, such as assigning to a grouped property. It also syntax-checks the patched
C++. `install-system.sh` runs it before installing anything.

## Uninstall

```sh
./uninstall.sh    # user part; prints the root commands that undo the system part
```
