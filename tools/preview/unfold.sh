#!/bin/sh
# Measures KRunner while its results unfold and fold: captures frames from the preview's KWin through
# ScreenShot2 at ~150 fps and reports frames where KRunner's top edge is misplaced (old frame shifted)
# and how many different text layouts showed up (old frame stretched: text flickers).
#   tools/preview/unfold.sh ["query"]
# KRUNNER=path runs a dev build (tools/patch-dev.sh krunner), KRUNNER_ENV="VAR=value ..." sets KRunner's
# environment, KWIN_ENV the preview KWin's (e.g. __EGL_VENDOR_LIBRARY_FILENAMES=.../50_mesa.json to
# composite on the iGPU). Uses the light style on a flat wallpaper, 1600x1000 at scale 1, so the tracker
# can find edges and text. Frames stay in ~/.cache/plasma-glass/preview/frames.
set -eu
export STYLE="${STYLE:-repo-light}" WIDTH="${WIDTH:-1600}" HEIGHT="${HEIGHT:-1000}" SCALE="${SCALE:-1}"
. "$(dirname "$0")/common.sh"
QUERY="${1:-F}"
mkdir -p "$WORK"; TOOL_PYTHON=$(pil_python); export TOOL_PYTHON
"$TOOL_PYTHON" -I -c "from PIL import Image; Image.new('RGB', ($WIDTH, $HEIGHT), (150, 190, 215)).save('$WORK/flat.png')"
WALLPAPER="$WORK/flat.png" prepare
# KRunner centred at a fixed spot, whatever your own krunnerrc says
kwriteconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingCenterX 0.5
kwriteconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingTop 0.2
rm -rf "$WORK/frames" && mkdir -p "$WORK/frames"
export INDEXING="${INDEXING:-}" KRUNNER_ENV="${KRUNNER_ENV:-}" KWIN_ENV="${KWIN_ENV:-}" QUERY2="${QUERY2:-}" REFRESH="${REFRESH:-}" SECONDS_CAPTURED="${SECONDS_CAPTURED:-2.6}"
# KEYS="33 33 33 - 14": type these evdev key codes instead (- pauses 600 ms), 120 ms apart; 33:1500
# holds the key for 1.5 s (KRunner repeats it). SECONDS_CAPTURED: how long to capture (default 2.6).
if [ -n "${KEYS:-}" ]; then
    for k in $KEYS; do
        case "$k" in
            -) echo "wait 600" ;;
            *:*) echo "key ${k%:*} down"; echo "wait ${k#*:}"; echo "key ${k%:*} up"; echo "wait 120" ;;
            *) echo "key $k down"; echo "key $k up"; echo "wait 120" ;;
        esac
    done >"$WORK/type.in"
    export TYPE_INPUT="$WORK/type.in" FAKEINPUT
    FAKEINPUT=$(fakeinput)
fi
run_session unfold "$QUERY"
cat "$WORK/grab.log"
"$TOOL_PYTHON" -I "$HERE/frames.py" track "$WORK/frames"
