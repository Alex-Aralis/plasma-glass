#!/bin/sh
# Screenshot of KRunner showing QUERY, with your KRunner settings and the chosen Plasma Style.
#   tools/preview/krunner.sh OUT.png ["query"]        (see common.sh for STYLE, WALLPAPER, ...)
set -eu
. "$(dirname "$0")/common.sh"
OUT=$(realpath -m "${1:?usage: krunner.sh OUT.png [query]}"); QUERY="${2:-beurre blanc sauce}"
# INDEXING="DELAY DURATION": a stand-in search service indexes for DURATION s after DELAY s (the bar)
if [ -n "${INDEXING:-}" ]; then TOOL_PYTHON=$(pil_python); export TOOL_PYTHON INDEXING; fi
prepare
run_session krunner "$QUERY"
crop_to_changes "$OUT"
