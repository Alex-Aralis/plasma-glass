#!/bin/sh
# Your panel in a real plasmashell on the preview's virtual display, floating or docked, as a screenshot
# or a video of the screen's bottom (the panel, its floating gap and its shadow).
#   tools/preview/panel.sh OUT.png          as your panel is set up (floating: detached)
#   DOCK=1 tools/preview/panel.sh OUT.png   a maximized window touches it, so a floating panel docks
#                                           (attached), as it does on your desktop
#   tools/preview/panel.sh OUT.mp4          a video: floating, then a window maximizes (the panel docks) and
#                                           is restored (it floats again): MAX_AT and RESTORE_AT s in (1.5,
#                                           4.5) of SECONDS_CAPTURED (7); a lossless OUT.mkv stays beside it
# COLORS=BreezeDark (any colour scheme's name) applies that scheme instead of yours (the dark style follows
# it). FLOATING=0|1 overrides your panel's floating setting, CROP is the strip's height (logical px, default
# 140), START the strip's left edge and CROP_WIDTH its width (default the screen's). The screen is
# 1600x1000 at scale 1 unless WIDTH, HEIGHT, SCALE say otherwise; WALLPAPER, STYLE, KWIN_WAYLAND and
# KWIN_ENV as in common.sh (the wallpaper goes into the desktop's config, since plasmashell draws it).
# plasmashell runs with copies of your layout and plasmashellrc and the same private bus as popup.sh's.
set -eu
export WIDTH="${WIDTH:-1600}" HEIGHT="${HEIGHT:-1000}" SCALE="${SCALE:-1}"
. "$(dirname "$0")/common.sh"
OUT=$(realpath -m "${1:?usage: panel.sh OUT.png|OUT.mp4}")
mkdir -p "$WORK"; TOOL_PYTHON=$(pil_python); export TOOL_PYTHON
prepare
rm -rf "$WORK/cache" "$WORK/state" && mkdir -p "$WORK/cache" "$WORK/state"
layout="$WORK/cfg/plasma-org.kde.plasma.desktop-appletsrc"
cp "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" "$layout" || die "no plasma-org.kde.plasma.desktop-appletsrc in ~/.config"
cp "$HOME/.config/plasmashellrc" "$WORK/cfg/" || die "no plasmashellrc in ~/.config"

# The activity manager on the preview's bus has this account's activity, not yours (it reads
# ~/.config/kactivitymanagerdrc), and plasmashell would make a new desktop for it with the default
# wallpaper: give your desktops its id
act=$(sed -n 's/^\([0-9a-f-]\{36\}\)=.*/\1/p' "$HOME/.config/kactivitymanagerdrc" 2>/dev/null | head -1)
[ -z "$act" ] || sed -i "s/^activityId=[0-9a-f-]\{36\}$/activityId=$act/" "$layout"
# every desktop shows WALLPAPER (plasmashell draws it from each desktop containment's config)
for c in $(awk '/^\[Containments\]\[[0-9]+\]$/{h=$0} /^plugin=org\.kde\.(plasma\.folder|desktopcontainment)$/{print h}' "$layout" \
           | sed 's/.*\[\([0-9]*\)\]$/\1/'); do
    kwriteconfig6 --file "$layout" --group Containments --group "$c" --group Wallpaper --group org.kde.image \
        --group General --key Image "file://$WALLPAPER_FILE"
done
if [ -n "${COLORS:-}" ]; then
    XDG_CONFIG_HOME="$WORK/cfg" QT_QPA_PLATFORM=offscreen plasma-apply-colorscheme "$COLORS" >"$WORK/colors.log" 2>&1 || die "colour scheme $COLORS: $(cat "$WORK/colors.log")"
fi
if [ -n "${FLOATING:-}" ]; then
    for p in $(sed -n 's/^\[PlasmaViews\]\[Panel \([0-9]*\)\]$/\1/p' "$WORK/cfg/plasmashellrc"); do
        kwriteconfig6 --file "$WORK/cfg/plasmashellrc" --group PlasmaViews --group "Panel $p" --key floating "$FLOATING"
    done
fi

# the strip at the screen's bottom, in logical px
crop=${CROP:-140}
export PANEL_AREA
PANEL_AREA=$(awk -v w="$WIDTH" -v h="$HEIGHT" -v s="$SCALE" -v c="$crop" -v x="${START:-0}" -v cw="${CROP_WIDTH:-0}" \
    'BEGIN { W = int(w / s); if (cw == 0) cw = W - x; printf "{\"x\": %d, \"y\": %d, \"width\": %d, \"height\": %d}", x, int(h / s) - c, cw, c }')

plasmashell_bus
case "$OUT" in
    *.mp4)
        export REFRESH="${REFRESH:-120000}" SECONDS_CAPTURED="${SECONDS_CAPTURED:-7}" MAX_AT="${MAX_AT:-1.5}" \
            RESTORE_AT="${RESTORE_AT:-4.5}" PAD=0
        rm -f "$WORK/record.mkv"
        DBUS_CONFIG="$WORK/dbus.conf" XDG_CACHE_HOME="$WORK/cache" XDG_STATE_HOME="$WORK/state" run_session panel record
        cat "$WORK/grab.log"
        [ -s "$WORK/record.mkv" ] || die "nothing recorded (see $WORK/*.log)"
        mv "$WORK/record.mkv" "${OUT%.*}.mkv"
        ffmpeg -v error -y -i "${OUT%.*}.mkv" -vf "crop=trunc(iw/2)*2:trunc(ih/2)*2" \
            -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -movflags +faststart "$OUT"
        echo "$OUT"
        ;;
    *)
        DBUS_CONFIG="$WORK/dbus.conf" XDG_CACHE_HOME="$WORK/cache" XDG_STATE_HOME="$WORK/state" \
            run_session panel "$([ "${DOCK:-0}" = 1 ] && echo dock || echo float)"
        "$TOOL_PYTHON" -I - "$WORK/shots/app.png" "$OUT" "$PANEL_AREA" "$SCALE" <<'PY'
import json, sys
from PIL import Image
shot, out, area, scale = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), float(sys.argv[4])
box = [round(v * scale) for v in (area["x"], area["y"], area["x"] + area["width"], area["y"] + area["height"])]
Image.open(shot).convert("RGB").crop(box).save(out)
print(out)
PY
        ;;
esac
pattern='Binding loop|TypeError|ReferenceError|panel-background|\.qml:[0-9]+'
echo "plasmashell warnings:"; { grep -E "$pattern" "$WORK/app.log" || echo none; } | sed 's/^/  /' | head -20
