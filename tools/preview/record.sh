#!/bin/sh
# Records KRunner on the preview's virtual display into a video, cropped to the window (PAD px around it):
# results for QUERY with the busy feedback running all along (KRUNNER_BUSY_DEMO=1; BUSY=0 for none).
#   tools/preview/record.sh OUT.mp4 ["query"]
# SECONDS_CAPTURED: how long (default 6). QUERY2: a second query, QUERY2_AT s in (default 2), to record
# the results changing or unfolding (QUERY "" or one with no results starts it folded away). The lossless
# capture stays next to OUT as OUT.mkv, for cuts and side-by-sides. KRUNNER, KRUNNER_ENV and KWIN_ENV as
# in unfold.sh; STYLE, WALLPAPER, ... in common.sh.
# The virtual screen runs at 120 Hz (REFRESH, mHz), so each of the video's 60 frames a second shows
# KRunner as it was at most 8 ms before; at scale 1, since that mode is WIDTH x HEIGHT device pixels.
set -eu
export WIDTH="${WIDTH:-1920}" HEIGHT="${HEIGHT:-1200}" SCALE="${SCALE:-1}"
. "$(dirname "$0")/common.sh"
OUT=$(realpath -m "${1:?usage: record.sh OUT.mp4 [query]}"); QUERY="${2-system settings}"
mkdir -p "$WORK"; TOOL_PYTHON=$(pil_python); export TOOL_PYTHON
prepare
# HOVER="X Y, X Y, ...": the pointer rests at each spot (screen pixels) for HOVER_HOLD s (default 3)
# while recording, from the start, to record hover effects
if [ -n "${HOVER:-}" ]; then
    FAKEINPUT=$(fakeinput); HOVER_INPUT="$WORK/hover.in"; export FAKEINPUT HOVER_INPUT
    echo "$HOVER" | tr ',' '\n' | while read -r x y; do
        printf 'move %s %s\nwait 50\nby 1 0\nwait %s\n' "$x" "$y" "$(awk "BEGIN{print ${HOVER_HOLD:-3}*1000-50}")"
    done >"$HOVER_INPUT"
fi
# KRunner centred at a fixed spot, whatever your own krunnerrc says
kwriteconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingCenterX 0.5
kwriteconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingTop 0.2
export KRUNNER_ENV="KRUNNER_BUSY_DEMO=${BUSY:-1} ${KRUNNER_ENV:-}" KWIN_ENV="${KWIN_ENV:-}" \
    REFRESH="${REFRESH:-120000}" SECONDS_CAPTURED="${SECONDS_CAPTURED:-6}"
rm -f "$WORK/record.mkv"
run_session record "$QUERY"
cat "$WORK/grab.log"
[ -s "$WORK/record.mkv" ] || die "nothing recorded (see $WORK/*.log)"
mv "$WORK/record.mkv" "${OUT%.*}.mkv"
ffmpeg -v error -y -i "${OUT%.*}.mkv" -vf "crop=trunc(iw/2)*2:trunc(ih/2)*2" \
    -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -movflags +faststart "$OUT"
echo "$OUT"
