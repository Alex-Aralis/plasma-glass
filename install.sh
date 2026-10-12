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

DO_SEARCH=1 DO_STYLE=1 DO_SETTINGS=1 REEXPORT=0 KEEP_EXPORT_VENV=0 STYLE=liquid-glass
for arg in "$@"; do
    case "$arg" in
        --no-search) DO_SEARCH=0 ;;
        --no-style) DO_STYLE=0 ;;
        --no-settings) DO_SETTINGS=0 ;;
        --light) STYLE=liquid-glass-light ;;
        --reexport) REEXPORT=1 ;;
        --keep-export-venv) KEEP_EXPORT_VENV=1 ;;
        -h|--help)
            cat <<EOF
usage: ./install.sh [options]
  --no-search         skip the semantic search service and KRunner plugin
  --no-style          skip the Liquid Glass Plasma Styles
  --light             apply Liquid Glass Light instead of Liquid Glass (both get installed)
  --no-settings       skip the KRunner/Plasma settings (desktop/plasma-settings.sh)
  --reexport          re-export the model even if it is already installed
  --keep-export-venv  keep the PyTorch venv used for the model export (~3 GB)
EOF
            exit 0 ;;
        *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

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
fi

if [ "$DO_STYLE" = 1 ]; then
    say "Liquid Glass Plasma Styles (applying $STYLE)"
    install -D -m 644 "$REPO/theme/liquid-glass/generate.py" "$STYLE_DIR/generate.py"
    "$PYTHON" "$STYLE_DIR/generate.py"  # writes liquid-glass and liquid-glass-light
    # drop cached renders of older versions of the styles, then apply one
    case "$(kreadconfig6 --file plasmarc --group Theme --key name)" in
        liquid-glass*) plasma-apply-desktoptheme default >/dev/null 2>&1 || true ;;
    esac
    rm -f "${XDG_CACHE_HOME:-$HOME/.cache}"/plasma_theme_liquid-glass*.kcache
    plasma-apply-desktoptheme "$STYLE"
    # "Test Notifications" launcher (KRunner / start menu; right-click for single kinds) to check popups
    install -D -m 755 "$REPO/desktop/test-notifications.sh" "$HOME/.local/bin/plasma-glass-test-notifications"
    mkdir -p "$DATA/applications"
    sed "s|@BIN@|$HOME/.local/bin/plasma-glass-test-notifications|g" "$REPO/desktop/test-notifications.desktop.in" \
        > "$DATA/applications/plasma-glass-test-notifications.desktop"
    kbuildsycoca6 >/dev/null 2>&1 || true
fi

if [ "$DO_SETTINGS" = 1 ]; then
    say "KRunner / Plasma settings"
    sh "$REPO/desktop/plasma-settings.sh"
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
EOF
