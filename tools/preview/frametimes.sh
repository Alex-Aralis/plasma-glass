#!/bin/sh
# Dropped frames while KRunner's dropdown folds and unfolds: KRunner with results for "f", then Backspace (it
# folds) and "f" (it unfolds) three times, STEP ms apart (default 1500), while KWin logs every frame
# (KWIN_LOG_PERFORMANCE_DATA: when each page flip was due and when it came, and the frame's render time) and a
# KWin script logs each change of KRunner's size with the time. frametimes.py then prints, for each fold and
# unfold, the steps that came more than 1.5 frames after the one before (frames KRunner dropped) and the vblanks
# KWin skipped then (KWin late, or nothing new to show).
#   tools/preview/frametimes.sh OUTDIR
# NOGLASS=1: KWin's built-in blur in place of the Liquid Glass effect. KRUNNER, KRUNNER_ENV (QSG_RENDER_TIMING=1:
# KRunner's own frame timings, in app.log), KWIN_EFFECT, STYLE, WALLPAPER as elsewhere. Run it on the machine
# whose frames drop: the laptop's CPU shows what the main box's hides.
set -eu
OUT=$(realpath -m "${1:?usage: frametimes.sh OUTDIR}")
export KWIN_ENV="KWIN_LOG_PERFORMANCE_DATA=1 ${KWIN_ENV:-}"
. "$(dirname "$0")/common.sh"
prepare
kwriteconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingCenterX 0.5
kwriteconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingTop 0.2
if [ "${NOGLASS:-0}" = 1 ]; then
    kwriteconfig6 --file "$WORK/cfg/kwinrc" --group Plugins --key blurEnabled true
    kwriteconfig6 --file "$WORK/cfg/kwinrc" --group Plugins --key liquidglassEnabled false
fi
for _ in 1 2 3; do
    printf 'key 14 down\nkey 14 up\nwait %s\nkey 33 down\nkey 33 up\nwait %s\n' "${STEP:-1500}" "${STEP:-1500}"
done >"$WORK/drag.in"
export FAKEINPUT DRAG_INPUT="$WORK/drag.in" REOPEN= TRACK_TIMES=1
FAKEINPUT=$(fakeinput)
rm -rf "${OUT:?}" && mkdir -p "$OUT"
# KWin writes its log into its working directory
(cd "$OUT" && run_session drag "f")
grep -a 'KRUNNER' "$WORK/kwin.log" | sed 's/.*KRUNNER /KRUNNER /' >"$OUT/krunner.log"
cp "$WORK/app.log" "$OUT/"
# the script's times are the wall clock's, KWin's the monotonic clock's
python3 -c 'import time; print((time.time() - time.monotonic()) * 1000)' >"$OUT/clock-offset"
python3 "$HERE/frametimes.py" "$OUT"
