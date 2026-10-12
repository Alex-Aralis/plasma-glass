#!/bin/sh
# Screenshot of a notification-like Plasma dialog (frame, padding, text field, highlight, scrollbar).
#   tools/preview/dialog.sh OUT.png                    (see common.sh for STYLE, WALLPAPER, ...)
set -eu
. "$(dirname "$0")/common.sh"
OUT=$(realpath -m "${1:?usage: dialog.sh OUT.png}")
prepare
run_session dialog
crop_to_changes "$OUT"
