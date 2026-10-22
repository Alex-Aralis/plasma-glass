#!/bin/sh
# Screenshot of System Settings opened on a page, as KRunner's System Settings results open it.
#   tools/preview/settings.sh OUT.png KCM ["ARGS"]      e.g. kcm_keys "kwin Maximize Window"
# ARGS2="..." then sends other arguments to the open page (OUT-before.png is just before).
# SYSTEMSETTINGS_ENV="QT_PLUGIN_PATH=$(tools/patch-dev.sh kcm-keys)" loads a dev build of the Shortcuts page.
set -eu
. "$(dirname "$0")/common.sh"
OUT=$(realpath -m "${1:?usage: settings.sh OUT.png KCM [ARGS]}"); KCM="${2:?usage: settings.sh OUT.png KCM [ARGS]}"
export ARGS2="${ARGS2:-}" SYSTEMSETTINGS_ENV="${SYSTEMSETTINGS_ENV:-}"
prepare
run_session settings "$KCM" "${3:-}"
crop_to_changes "$OUT" ${ARGS2:+"$WORK/shots/before.png" "${OUT%.png}-before.png"}
