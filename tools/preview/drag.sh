#!/bin/sh
# Drags KRunner from one virtual screen onto the next with fake pointer input (Meta+drag from the
# middle of the query field) and prints where it went, screen by screen; the last screenshot shows
# whether the query and results came along.
#   tools/preview/drag.sh ["query"]
# KRUNNER=path runs a dev build (tools/patch-dev.sh krunner), KRUNNER_ENV its environment. Two 1280x800 screens at scale 1, side by
# side; KRunner starts centred on the first, its top at 20%.
set -eu
export OUTPUTS=2 WIDTH=1280 HEIGHT=800 SCALE=1 STYLE="${STYLE:-repo-light}"
. "$(dirname "$0")/common.sh"
prepare
kwriteconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingCenterX 0.5
kwriteconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingTop 0.2
{
    echo "key 125 down"; echo "move 640 200"; echo "wait 300"; echo "down"; echo "wait 100"
    i=0; while [ $i -lt "${DRAG_STEPS:-75}" ]; do echo "by 20 0"; echo "wait 16"; i=$((i + 1)); done
    echo "wait 300"; echo "up"; echo "key 125 up"; echo "wait 300"
    for k in ${TYPE:-}; do echo "key $k down"; echo "key $k up"; echo "wait 100"; done
} >"$WORK/drag.in"
export FAKEINPUT DRAG_INPUT="$WORK/drag.in"
FAKEINPUT=$(fakeinput)
run_session drag "${1:-F}"
grep -a 'KRUNNER' "$WORK/kwin.log" | sed 's/.*KRUNNER /  /' | uniq
echo "saved: FloatingCenterX=$(kreadconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingCenterX) FloatingTop=$(kreadconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingTop)"
echo "screenshot: $WORK/shots/app.png"
