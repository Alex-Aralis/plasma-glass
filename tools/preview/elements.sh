#!/bin/sh
# Print SVG element rects exactly as Plasma measures them (no display needed). Every frame piece
# should come out at its intended whole-pixel size; anything else misaligns the frame.
#   tools/preview/elements.sh translucent/dialogs/background topleft top center hint-top-margin
#   STYLE=default tools/preview/elements.sh widgets/scrollbar slider-topleft      # compare with Breeze
set -eu
. "$(dirname "$0")/common.sh"
[ $# -ge 2 ] || die "usage: elements.sh IMAGEPATH id..."
prepare
XDG_CONFIG_HOME="$WORK/cfg" XDG_DATA_HOME="$WORK/data" \
XDG_DATA_DIRS="$HOME/.local/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" QT_QPA_PLATFORM=offscreen \
    timeout 30 qml6 "$HERE/qml/elements.qml" -- "$@" 2>&1 | sed -n 's/.*ELEMENT //p' | column -t
