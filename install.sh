#!/bin/sh
# plasma-glass installer, user part. Run from the repo as your normal user (not root):
#
#   ./install.sh                 everything: search service + KRunner plugin, Liquid Glass style, settings
#   ./install.sh --help          options
#
# The system part (Intel GPU compute runtime, Portage patches for KRunner/notifications/milou) is
# install-system.sh, which needs root. Re-running either script is safe.
set -eu

REPO=$(cd "$(dirname "$0")" && pwd)
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
APP_DIR="$DATA/embedsearch"
STYLE_DIR="$DATA/plasma/desktoptheme/liquid-glass"
EXPORT_VENV="${XDG_CACHE_HOME:-$HOME/.cache}/plasma-glass/export-venv"
PYTHON="${PYTHON:-python3}"

DO_SEARCH=1 DO_STYLE=1 DO_SETTINGS=1 REEXPORT=0 KEEP_EXPORT_VENV=0 STYLE=
for arg in "$@"; do
    case "$arg" in
        --no-search) DO_SEARCH=0 ;;
        --no-style) DO_STYLE=0 ;;
        --no-settings) DO_SETTINGS=0 ;;
        --light) STYLE=liquid-glass-light ;;
        --dark) STYLE=liquid-glass ;;
        --dark-frost) STYLE=liquid-glass-dark-frost ;;
        --reexport) REEXPORT=1 ;;
        --keep-export-venv) KEEP_EXPORT_VENV=1 ;;
        -h|--help)
            cat <<EOF
usage: ./install.sh [options]
  --no-search         skip the semantic search service and KRunner plugin
  --no-style          skip the Liquid Glass Plasma Styles
  --light, --dark, --dark-frost
                      apply Liquid Glass Light, Liquid Glass or Liquid Glass Dark Frost (all three get
                      installed; by default the one in use stays, and Liquid Glass if none is)
  --no-settings       skip the KRunner/Plasma settings (desktop/plasma-settings.sh)
  --reexport          re-export the model even if it is already installed
  --keep-export-venv  keep the PyTorch venv used for the model export (~3 GB)
EOF
            exit 0 ;;
        *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done
# keep Liquid Glass Light or Dark Frost if it's in use (plasma-glass-mode switches between them)
if [ -z "$STYLE" ]; then
    STYLE=$(kreadconfig6 --file plasmarc --group Theme --key name 2>/dev/null || true)
    case "$STYLE" in
        liquid-glass-light | liquid-glass-dark-frost) ;;
        *) STYLE=liquid-glass ;;
    esac
fi

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "run this as your normal user; the root part is install-system.sh"
command -v kwriteconfig6 >/dev/null || die "kwriteconfig6 not found: this needs KDE Plasma 6"
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null \
    || die "need Python 3.11+ (set PYTHON=/path/to/python3 to pick one)"

fill() {  # fill TEMPLATE DEST: substitute @APP_DIR@
    mkdir -p "$(dirname "$2")"
    sed "s|@APP_DIR@|$APP_DIR|g" "$1" > "$2"
}

if [ "$DO_SEARCH" = 1 ]; then
    # OpenVINO sends a Google Analytics event on every import (and on model export) unless its consent
    # file says 0. Opt out before anything imports it; an existing choice is kept.
    mkdir -p "$HOME/intel"
    [ -e "$HOME/intel/openvino_telemetry" ] || echo 0 > "$HOME/intel/openvino_telemetry"

    say "Search runtime ($APP_DIR/venv)"
    mkdir -p "$APP_DIR/model"
    [ -x "$APP_DIR/venv/bin/python" ] || "$PYTHON" -m venv "$APP_DIR/venv"
    "$APP_DIR/venv/bin/pip" install -q --upgrade pip
    "$APP_DIR/venv/bin/pip" install -q -r "$REPO/search/requirements.txt"
    install -m 644 "$REPO/search/embedsearch.py" "$APP_DIR/embedsearch.py"
    install -m 644 "$REPO/search/settings-index.json" "$APP_DIR/settings-index.json"

    if [ "$REEXPORT" = 1 ] || [ ! -f "$APP_DIR/model/embeddinggemma2_text.xml" ]; then
        say "Exporting EmbeddingGemma 2 to OpenVINO (one-time: ~1.5 GB model download + PyTorch)"
        [ -x "$EXPORT_VENV/bin/python" ] || { mkdir -p "$(dirname "$EXPORT_VENV")"; "$PYTHON" -m venv "$EXPORT_VENV"; }
        "$EXPORT_VENV/bin/pip" install -q --upgrade pip
        # torchvision: the model's processor imports the Gemma 4 image code even for text-only use
        "$EXPORT_VENV/bin/pip" install -q torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cpu
        "$EXPORT_VENV/bin/pip" install -q -r "$REPO/search/requirements-export.txt"
        "$EXPORT_VENV/bin/python" "$REPO/search/export_model.py" --out "$APP_DIR/model"
        rm -rf "$APP_DIR/ov_cache"  # compiled kernels belong to the old model
        [ "$KEEP_EXPORT_VENV" = 1 ] || rm -rf "$EXPORT_VENV"
    else
        echo "model already installed (use --reexport to rebuild it)"
    fi

    say "KRunner plugin, D-Bus activation, systemd user service, embedsearch command"
    install -D -m 644 "$REPO/desktop/krunner-embedsearch.desktop" "$DATA/krunner/dbusplugins/embedsearch.desktop"
    # "Index" launcher (KRunner / start menu): indexes now instead of at the next interval
    install -D -m 644 "$REPO/desktop/embedsearch-index.desktop" "$DATA/applications/plasma-glass-index.desktop"
    fill "$REPO/desktop/local.embedsearch.service.in" "$DATA/dbus-1/services/local.embedsearch.service"
    fill "$REPO/desktop/embedsearch.service.in" "$CONF/systemd/user/embedsearch.service"
    fill "$REPO/desktop/embedsearch.in" "$HOME/.local/bin/embedsearch"
    chmod +x "$HOME/.local/bin/embedsearch"
    # writes ~/.config/embedsearch/config.toml with defaults if missing (an existing config is kept)
    "$APP_DIR/venv/bin/python" -I -c "import sys; sys.path.insert(0, '$APP_DIR'); import embedsearch; embedsearch.load_config()"

    command -v pdftotext >/dev/null || warn "pdftotext not found: PDFs won't be indexed (emerge app-text/poppler with USE=utils)"
    systemctl --user daemon-reload
    systemctl --user enable embedsearch.service
    systemctl --user restart embedsearch.service
    kbuildsycoca6 >/dev/null 2>&1 || true
fi

if [ "$DO_STYLE" = 1 ]; then
    say "Liquid Glass Plasma Styles (applying $STYLE)"
    install -D -m 644 "$REPO/theme/liquid-glass/generate.py" "$STYLE_DIR/generate.py"
    "$PYTHON" "$STYLE_DIR/generate.py"  # writes liquid-glass, liquid-glass-light and liquid-glass-dark-frost
    # drop cached renders of older versions of the styles, then apply one
    case "$(kreadconfig6 --file plasmarc --group Theme --key name)" in
        liquid-glass*) plasma-apply-desktoptheme default >/dev/null 2>&1 || true ;;
    esac
    rm -f "${XDG_CACHE_HOME:-$HOME/.cache}"/plasma_theme_liquid-glass*.kcache
    plasma-apply-desktoptheme "$STYLE"
    # Liquid Glass, Dark Frost and Light as global themes, and KDE's default dark and light ones: its Dark
    # Mode switch (the tray's Brightness and Color, Quick Settings) applies those, and with Breeze's it put
    # the Plasma Style back to Breeze. Only the style is applied here, so your colours stay as they are. The
    # default dark one is the dark style applied here, or with Light, the dark one you last picked
    for package in "$REPO"/theme/look-and-feel/*/; do
        dest="$DATA/plasma/look-and-feel/$(basename "$package")"
        rm -rf "${dest:?}" && mkdir -p "$DATA/plasma/look-and-feel" && cp -r "$package" "$dest"
    done
    case "$STYLE" in
        liquid-glass-light)
            dark=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel)
            [ "$dark" = plasma-glass.liquid-glass-dark-frost ] || dark=plasma-glass.liquid-glass ;;
        *) dark="plasma-glass.$STYLE" ;;
    esac
    kwriteconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel "$dark"
    kwriteconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel plasma-glass.liquid-glass-light
    kwriteconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage "plasma-glass.$STYLE"
    # "Test Notifications" launcher (KRunner / start menu; right-click for single kinds) to check popups
    install -D -m 755 "$REPO/desktop/test-notifications.sh" "$HOME/.local/bin/plasma-glass-test-notifications"
    mkdir -p "$DATA/applications"
    sed "s|@BIN@|$HOME/.local/bin/plasma-glass-test-notifications|g" "$REPO/desktop/test-notifications.desktop.in" \
        > "$DATA/applications/plasma-glass-test-notifications.desktop"
    # "Liquid Glass Tuning": the liquid in KRunner's glass and the dark glass, live (it writes plasma-glassrc, which
    # the patched KRunner and KWin follow)
    install -D -m 644 "$REPO/desktop/plasma-glass-tune.qml" "$DATA/plasma-glass/plasma-glass-tune.qml"
    printf '#!/bin/sh\nexec qml6 -a widget "%s" "$@"\n' "$DATA/plasma-glass/plasma-glass-tune.qml" > "$HOME/.local/bin/plasma-glass-tune"
    chmod +x "$HOME/.local/bin/plasma-glass-tune"
    sed "s|@BIN@|$HOME/.local/bin/plasma-glass-tune|g" "$REPO/desktop/plasma-glass-tune.desktop.in" \
        > "$DATA/applications/plasma-glass-tune.desktop"
    # "Toggle Dark/Light Mode": the Liquid Glass (or Dark Frost) or Liquid Glass Light global theme
    install -D -m 755 "$REPO/desktop/plasma-glass-mode.sh" "$HOME/.local/bin/plasma-glass-mode"
    sed "s|@BIN@|$HOME/.local/bin/plasma-glass-mode|g" "$REPO/desktop/plasma-glass-mode.desktop.in" \
        > "$DATA/applications/plasma-glass-mode.desktop"
    kbuildsycoca6 >/dev/null 2>&1 || true
    # the Liquid Glass effect (install-system.sh puts it in KWin's plugin folder): in place of the built-in
    # blur from now on, swapped into the running KWin; plasma-glass-reload-kwin swaps in a new build
    sed "s|@REPO@|$REPO|g" "$REPO/desktop/plasma-glass-reload-kwin.in" > "$HOME/.local/bin/plasma-glass-reload-kwin"
    chmod 755 "$HOME/.local/bin/plasma-glass-reload-kwin"
    if [ -e "$(sh "$REPO/tools/kwin-effect.sh" plugindir)/liquidglass.so" ]; then
        sh "$REPO/tools/kwin-effect.sh" enable
        sh "$REPO/tools/kwin-effect.sh" reload || warn "KWin didn't take the Liquid Glass effect now; it loads from the next login"
    else
        warn "the Liquid Glass effect isn't built yet (sudo ./install-system.sh): KWin keeps its plain blur until it is"
    fi
fi

if [ "$DO_SETTINGS" = 1 ]; then
    say "KRunner / Plasma settings"
    sh "$REPO/desktop/plasma-settings.sh"
    # KRunner's drop-ins (session.slice instead of background.slice, and software rendering on NVIDIA
    # until the Qt fixes are built) were plasma-glass's until 2026-10-17 and are kde-fixes' now, which
    # replaces plasma-glass-priority.conf and plasma-glass-software-render.conf with its own
    dropins="$CONF/systemd/user/plasma-krunner.service.d"
    if [ ! -e "$dropins/kde-fixes-priority.conf" ] && [ ! -e "$dropins/plasma-glass-priority.conf" ]; then
        warn "KRunner's priority drop-in is kde-fixes' now: run its install-user.sh (KRunner otherwise runs in background.slice and lags when apps are busy)"
    fi
fi

kquitapp6 krunner >/dev/null 2>&1 || true  # KRunner picks everything up on its next start

if [ "$DO_SEARCH" = 1 ]; then
    say "Status"
    if "$APP_DIR/venv/bin/python" -I -c "import sys; sys.path.insert(0, '$APP_DIR'); import embedsearch, openvino as ov; sys.exit(not embedsearch.intel_gpu(ov.Core()))" 2>/dev/null; then
        echo "Intel GPU visible to OpenVINO: search runs on the GPU (float16)."
    else
        warn "OpenVINO sees no Intel GPU, so search runs on the CPU (slower). Run: sudo ./install-system.sh"
    fi
    echo "First indexing runs in the background: journalctl --user -fu embedsearch"
    echo "Folders to index: ${CONF}/embedsearch/config.toml (then: systemctl --user restart embedsearch)"
fi
cat <<EOF

Done. If you haven't yet, run the system part for the GPU runtime and the KRunner/notification patches:
    sudo ./install-system.sh
and kde-fixes for the KDE and Qt bug fixes (https://github.com/Alex-Aralis/kde-fixes):
    sudo ./install.sh; ./install-user.sh
EOF
