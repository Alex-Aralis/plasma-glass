#!/bin/sh
# Probes on the REAL screens, for what the virtual display can't show (refresh rates, several GPUs).
# The windows are small, never take keyboard focus and close by themselves (or on Ctrl-C), but they
# do appear on your monitors: say so before running these for someone. Positions are global
# coordinates (kscreen-doctor -o).
#
#   screen.sh fps X,Y [X,Y...]
#       a 200 px animated window per position, all from one process (several windows in one app use
#       Qt Quick's shared animation timer, like plasmashell); prints frames per second and animation
#       speed (1.00 = right) per window after 6 s. ENV="VAR=value ..." sets the probe's environment,
#       e.g. ENV="$(~/Projects/kde-fixes/tools/patch-dev.sh qt)" for a dev Qt, QSG_RENDER_LOOP=basic for Qt Quick's GUI
#       thread loop (what NVIDIA clients get), QSG_INFO=1 for Qt's notes (in the log).
#   screen.sh glass [--light] [--shot OUT.png] X,Y [X,Y...]
#       a 700 px grey square (GRAY, default 190) per position with the Plasma Style's glass on top,
#       blurred by KWin. With --shot: screenshot, print the grey and the glass centre per position,
#       close. Without: stays until Ctrl-C, for comparing by eye (a screenshot is re-rendered by
#       KWin, so it misses anything that goes wrong after compositing). --light uses Liquid Glass
#       Light for the glass.
# Logs and screenshots: ~/.cache/plasma-glass/screenprobe
set -eu
. "$(dirname "$0")/../preview/common.sh"
OUT="${XDG_CACHE_HOME:-$HOME/.cache}/plasma-glass/screenprobe"
mkdir -p "$OUT"
PIDS=""
trap 'kill $PIDS 2>/dev/null || true' EXIT INT TERM

# kwin_script FILE: run a KWin script (window placement) once
kwin_script() {
    id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$1" screenprobe)
    qdbus6 org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null
    qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript screenprobe >/dev/null
}

fps() {
    [ $# -gt 0 ] || die "usage: screen.sh fps X,Y [X,Y...]"
    # shellcheck disable=SC2086
    env ${ENV:-} qml6 "$HERE/fps.qml" -- fps $# >"$OUT/fps.log" 2>&1 &
    pid=$!
    PIDS="$pid"
    sleep 2
    i=0
    : >"$OUT/place.js"
    for pos in "$@"; do
        i=$((i + 1))
        printf 'for (const w of workspace.windowList()) if (w.caption === "fps-%d") w.frameGeometry = {x: %s, y: %s, width: 200, height: 200};\n' \
            "$i" "${pos%,*}" "${pos#*,}" >>"$OUT/place.js"
    done
    kwin_script "$OUT/place.js"
    wait "$pid" || true
    PIDS=""
    grep -a 'FPS' "$OUT/fps.log" | sed 's/.*FPS /  /'
}

glass() {
    light="" shot=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --light) light=1; shift ;;
            --shot) shot=$(realpath -m "$2"); shift 2 ;;
            *) break ;;
        esac
    done
    [ $# -gt 0 ] || die "usage: screen.sh glass [--light] [--shot OUT.png] X,Y [X,Y...]"
    if [ -n "$light" ]; then  # this process's own config: same settings, the light style
        mkdir -p "$OUT/light-config"
        cp "$HOME/.config/kdeglobals" "$OUT/light-config/" 2>/dev/null || true
        printf '[Theme]\nname=liquid-glass-light\n' >"$OUT/light-config/plasmarc"
    fi
    i=0
    for _ in "$@"; do
        i=$((i + 1))
        qml6 "$HERE/band.qml" -- "band-$i" "${GRAY:-190}" >/dev/null 2>&1 &
        PIDS="$PIDS $!"
        if [ -n "$light" ]; then
            XDG_CONFIG_HOME="$OUT/light-config" qml6 "$HERE/glass.qml" -- "glass-$i" >/dev/null 2>&1 &
        else
            qml6 "$HERE/glass.qml" -- "glass-$i" >/dev/null 2>&1 &
        fi
        PIDS="$PIDS $!"
    done
    sleep 3
    # bands first, then the glass centred on its band, each raised above the last
    i=0
    : >"$OUT/place.js"
    for pos in "$@"; do
        i=$((i + 1))
        cat >>"$OUT/place.js" <<JS
for (const w of workspace.windowList()) if (w.caption === "band-$i") { w.frameGeometry = {x: ${pos%,*}, y: ${pos#*,}, width: 700, height: 700}; workspace.raiseWindow(w); }
for (const w of workspace.windowList()) if (w.caption === "glass-$i") { const g = w.frameGeometry; w.frameGeometry = {x: ${pos%,*} + (700 - g.width) / 2, y: ${pos#*,} + (700 - g.height) / 2, width: g.width, height: g.height}; workspace.raiseWindow(w); }
JS
    done
    kwin_script "$OUT/place.js"
    if [ -z "$shot" ]; then
        echo "Showing; Ctrl-C to close."
        while :; do sleep 60; done
    fi
    sleep 1
    spectacle -b -n -f -o "$shot" >/dev/null 2>&1
    "$(pil_python)" -I - "$shot" "$@" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
for pos in sys.argv[2:]:
    x, y = map(int, pos.split(","))
    print(f"  {pos}: grey {im.getpixel((x + 5, y + 5))}, glass centre {im.getpixel((x + 350, y + 350))}")
PY
}

case "${1:-}" in
    fps) shift; fps "$@" ;;
    glass) shift; glass "$@" ;;
    *) sed -n '2,24p' "$0"; exit 2 ;;
esac
