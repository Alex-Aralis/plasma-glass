#!/bin/sh
# Screenshot of KRunner showing QUERY, with your KRunner settings and the chosen Plasma Style.
#   tools/preview/krunner.sh OUT.png ["query"]        (see common.sh for STYLE, WALLPAPER, ...)
set -eu
. "$(dirname "$0")/common.sh"
OUT=$(realpath -m "${1:?usage: krunner.sh OUT.png [query]}"); QUERY="${2:-beurre blanc sauce}"
# INDEXING="DELAY DURATION": a stand-in search service indexes for DURATION s after DELAY s (the bar)
if [ -n "${INDEXING:-}" ]; then TOOL_PYTHON=$(pil_python); export TOOL_PYTHON INDEXING; fi
# HOVER="X Y": the pointer rests there (screen coordinates) before the screenshot, to show a tooltip
if [ -n "${HOVER:-}" ]; then
    FAKEINPUT=$(fakeinput); HOVER_INPUT="$WORK/hover.in"; export FAKEINPUT HOVER_INPUT
    printf 'move %s\nwait 100\nby 1 0\n' "$HOVER" >"$HOVER_INPUT"
fi
prepare
run_session krunner "$QUERY"
crop_to_changes "$OUT"
