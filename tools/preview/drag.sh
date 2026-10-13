#!/bin/sh
# Drags KRunner from one virtual screen onto the next with fake pointer input (Meta+drag from the
# middle of the query field) and prints where it went, screen by screen; the last screenshot shows
# whether the query and results came along.
#   tools/preview/drag.sh ["query"]
# KRUNNER=path runs a dev build (tools/patch-dev.sh krunner), KRUNNER_ENV its environment. Two 1280x800
# screens at scale 1, side by side; KRunner starts centred on the first, its top at 20%. DRAG_STEPS
# (default 75) steps of 20 px to the right, from FROM (default "640 200", the query field; "640 330" is a
# result, whose own drag-and-drop must stay out of it), holding MOD (default 125, Meta; MOD= for none,
# e.g. FROM="640 762" drags by the glass's bottom rim). TYPE="30 31" types those keys (evdev codes) afterwards, to
# see whether KRunner still has the keyboard. REOPEN=1 then moves the pointer back to the first screen
# and closes and opens KRunner: it should come back where it was dragged.
set -eu
export OUTPUTS=2 WIDTH=1280 HEIGHT=800 SCALE=1 STYLE="${STYLE:-repo-light}"
. "$(dirname "$0")/common.sh"
MOD="${MOD-125}"
prepare
kwriteconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingCenterX 0.5
kwriteconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingTop 0.2
{
    [ -z "$MOD" ] || echo "key $MOD down"; echo "move ${FROM:-640 200}"; echo "wait 300"; echo "down"; echo "wait 100"
    i=0; while [ $i -lt "${DRAG_STEPS:-75}" ]; do echo "by 20 0"; echo "wait 16"; i=$((i + 1)); done
    echo "wait 300"; echo "up"; [ -z "$MOD" ] || echo "key $MOD up"; echo "wait 300"
    for k in ${TYPE:-}; do echo "key $k down"; echo "key $k up"; echo "wait 100"; done
    if [ -n "${REOPEN:-}" ]; then echo "move 100 100"; echo "wait 300"; fi
} >"$WORK/drag.in"
export FAKEINPUT DRAG_INPUT="$WORK/drag.in" REOPEN="${REOPEN:-}"
FAKEINPUT=$(fakeinput)
run_session drag "${1:-F}"
grep -a 'KRUNNER' "$WORK/kwin.log" | sed 's/.*KRUNNER /  /' | uniq
echo "saved: FloatingCenterX=$(kreadconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingCenterX) FloatingTop=$(kreadconfig6 --file "$WORK/cfg/krunnerrc" --group General --key FloatingTop)"
[ -z "${REOPEN:-}" ] || cat "$WORK/reopen.log"
echo "screenshot: $WORK/shots/app.png"
