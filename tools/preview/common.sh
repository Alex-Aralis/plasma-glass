# Shared by the preview scripts (sourced). Everything runs against throwaway copies of your Plasma
# config and a private data dir, on a virtual KWin display with its own D-Bus session, so nothing
# appears on your screen, takes keyboard focus or changes your real settings.
#
# Environment:
#   STYLE=repo         Plasma Style to preview: "repo" (default) or "repo-light" generate the Liquid Glass
#                      styles from this checkout into the private data dir; anything else is an
#                      installed style id
#   WALLPAPER=path     background image (default: your desktop wallpaper, else Breeze's "Next")
#   WIDTH/HEIGHT/SCALE virtual screen (default 1920x1200 at 1.1)
#   WALLPAPER_PAN=px/s the wallpaper scrolls up and down at this speed (record.sh: content moving behind
#                      the glass)
#   KWIN_WAYLAND=path  a dev build of KWin as the preview's compositor (KWIN_ENV: its environment)

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/plasma-glass/preview"
STYLE="${STYLE:-repo}"
export WIDTH="${WIDTH:-1920}" HEIGHT="${HEIGHT:-1200}" SCALE="${SCALE:-1.1}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in kwin_wayland dbus-run-session spectacle qml6 qdbus6 kwriteconfig6; do
    command -v "$tool" >/dev/null || die "$tool not found"
done

# A tiny venv with Pillow (cropping screenshots) and dbus-fast (frames.py), created on first use.
pil_python() {
    if [ ! -x "$WORK/venv/bin/python" ] || ! "$WORK/venv/bin/python" -c 'import PIL, dbus_fast' 2>/dev/null; then
        python3 -m venv "$WORK/venv" && "$WORK/venv/bin/pip" install -q pillow dbus-fast >&2 || die "could not set up the preview venv"
    fi
    echo "$WORK/venv/bin/python"
}

pick_wallpaper() {
    [ -n "${WALLPAPER:-}" ] && { echo "$WALLPAPER"; return; }
    img=$(grep -h '^Image=' "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null | head -1 | sed 's|^Image=||; s|^file://||')
    if [ -f "$img" ]; then echo "$img"; return; fi
    # a wallpaper package (or a missing file inside one): its largest image, in the dark variant
    # when the colour scheme is dark (as Plasma does)
    pkg=$(echo "${img:-/usr/share/wallpapers/Next}" | sed 's|/contents/.*||')
    [ -d "$pkg/contents" ] || pkg=/usr/share/wallpapers/Next
    dir="$pkg/contents/images"
    case "$(kreadconfig6 --file kdeglobals --group General --key ColorScheme)" in
        *[Dd]ark*) [ -d "$pkg/contents/images_dark" ] && dir="$pkg/contents/images_dark" ;;
    esac
    ls -S "$dir"/* 2>/dev/null | head -1
}

# Fresh private config (copies of yours) and data dir; generates the repo style if STYLE=repo.
prepare() {
    rm -rf "$WORK/cfg" "$WORK/data" "$WORK/shots"
    mkdir -p "$WORK/cfg" "$WORK/data" "$WORK/shots"
    for f in kdeglobals krunnerrc kwinrc breezerc kcminputrc; do
        [ -f "$HOME/.config/$f" ] && cp "$HOME/.config/$f" "$WORK/cfg/"
    done
    name="$STYLE"
    case "$STYLE" in
        repo|repo-light)
            d="$WORK/data/plasma/desktoptheme/liquid-glass"  # generate.py writes both styles from here
            mkdir -p "$d" && cp "$REPO/theme/liquid-glass/generate.py" "$d/" && python3 "$d/generate.py" >/dev/null
            name=liquid-glass; [ "$STYLE" = repo-light ] && name=liquid-glass-light ;;
    esac
    kwriteconfig6 --file "$WORK/cfg/plasmarc" --group Theme --key name "$name"
    export WALLPAPER_FILE
    WALLPAPER_FILE=$(pick_wallpaper)
}

# run_session MODE ARGS... : run session.sh on a private bus with the private config and data.
# ~/.local/share stays readable (after the private dir) for installed styles, KRunner plugins and
# D-Bus service files. EMBEDSEARCH_NO_REINDEX keeps a D-Bus-activated search service read-only.
# Services the private bus starts inherit its environment, so point them at the virtual display and
# drop X11: nothing from the preview (a wallet or portal prompt, say) can open on your real screen.
# DBUS_CONFIG=file runs the private bus with that config instead of the standard session one.
run_session() {
    PREVIEW_SOCK="wl-plasma-glass-preview-$$"
    env -u DISPLAY -u XAUTHORITY WAYLAND_DISPLAY="$PREVIEW_SOCK" PREVIEW_SOCK="$PREVIEW_SOCK" \
    XDG_DATA_HOME="$WORK/data" \
    XDG_DATA_DIRS="$HOME/.local/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" \
    EMBEDSEARCH_NO_REINDEX=1 WORK="$WORK" HERE="$HERE" \
        dbus-run-session ${DBUS_CONFIG:+--config-file="$DBUS_CONFIG"} -- sh "$HERE/session.sh" "$@"
}

# fakeinput : path to tools/preview/fakeinput.c, compiled on first use (pointer input for the preview)
fakeinput() {
    if [ ! -x "$WORK/fakeinput" ] || [ "$HERE/fakeinput.c" -nt "$WORK/fakeinput" ]; then
        xml=/usr/share/plasma-wayland-protocols/fake-input.xml
        mkdir -p "$WORK/fakeinput-src"
        wayland-scanner client-header "$xml" "$WORK/fakeinput-src/fake-input-client-protocol.h" &&
        wayland-scanner private-code "$xml" "$WORK/fakeinput-src/fake-input-protocol.c" &&
        # shellcheck disable=SC2046
        cc -O2 -o "$WORK/fakeinput" -I"$WORK/fakeinput-src" "$HERE/fakeinput.c" "$WORK/fakeinput-src/fake-input-protocol.c" \
            $(pkg-config --cflags --libs wayland-client) >&2 || die "could not build fakeinput (needs wayland-scanner, plasma-wayland-protocols)"
    fi
    echo "$WORK/fakeinput"
}

# crop_to_changes OUT : crop the app screenshot to what differs from the wallpaper-only screenshot
crop_to_changes() {
    "$(pil_python)" -I - "$WORK/shots/bg.png" "$WORK/shots/app.png" "$1" <<'PY'
import sys
from PIL import Image, ImageChops
bg, app = (Image.open(p).convert("RGB") for p in sys.argv[1:3])
box = ImageChops.difference(bg, app).convert("L").point(lambda v: 255 if v > 6 else 0).getbbox()
if not box:
    sys.exit("nothing appeared on the preview screen (see ~/.cache/plasma-glass/preview/*.log)")
pad = 48
app.crop((max(0, box[0] - pad), max(0, box[1] - pad), min(app.width, box[2] + pad), min(app.height, box[3] + pad))).save(sys.argv[3])
print(sys.argv[3])
PY
}
