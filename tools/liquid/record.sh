#!/bin/sh
# Drags across Kickoff in the preview's virtual KWin (tools/preview/panel.sh) with this checkout's Liquid Glass
# effect logging its clicks to DIR (KWIN_LIQUID_GLASS_CLICK_LOG: the presses, every liquid step, the ripples
# read back each frame), for `liquid.sh compare DIR`; DIR/glass.mp4 shows the glass as it ran.
#   tools/liquid/record.sh DIR ["X1 Y1 X2 Y2 MS, ..."]
# The default drags run at about 700, 1300 and 2000 px/s (screen px on the preview's 1600x1000; the preview's
# fake input sends a move every 8 ms, unevenly). POPUP, CROP, SECONDS_CAPTURED and the rest as in panel.sh.
set -eu
DIR=$(realpath -m "${1:?usage: record.sh DIR [DRAGS]}")
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$DIR" && rm -f "$DIR/log" "$DIR"/*.f32 "$DIR"/*.png
KWIN_EFFECT=repo KWIN_ENV="KWIN_LIQUID_GLASS_CLICK_LOG=$DIR ${KWIN_ENV:-}" POPUP="${POPUP:-kickoff}" CROP="${CROP:-760}" \
    CROP_WIDTH="${CROP_WIDTH:-640}" SECONDS_CAPTURED="${SECONDS_CAPTURED:-7}" \
    DRAGS="${2:-40 420 400 470 500, 40 650 400 560 250, 40 540 480 560 180}" sh "$HERE/../preview/panel.sh" "$DIR/glass.mp4"
[ -s "$DIR/log" ] || { echo "error: the effect logged nothing to $DIR/log" >&2; exit 1; }
echo "$DIR/log: $(grep -c '^step' "$DIR/log") steps, $(grep -c '^frame' "$DIR/log") frames read back"
