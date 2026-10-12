#!/bin/sh
# Screenshot of a system tray popup in a real plasmashell, and the QML warnings plasmashell logged.
#   tools/preview/popup.sh OUT.png [APPLET]            APPLET: volume (default), clipboard, ...
#   tools/preview/popup.sh OUT.png notify              the sample notifications (desktop/test-notifications.sh)
#   PANEL=mine tools/preview/popup.sh OUT.png [APPLET]  your own panels and tray instead (any tray applet)
# (see common.sh for STYLE, WALLPAPER, WIDTH, ...). plasmashell runs with a generated panel (a system
# tray holding volume and clipboard; floating and thickness as your first panel) on a plain desktop, or
# with a copy of your layout, with private config, data, cache and state dirs, and a private bus that
# may only start the activity manager, so no second kded, KDE Connect or powerdevil comes up next to
# your real ones (their applets just find them missing). The popup is opened through a global shortcut
# (KWin's kglobalaccel on the private bus).
set -eu
. "$(dirname "$0")/common.sh"
OUT=$(realpath -m "${1:?usage: popup.sh OUT.png [APPLET]}"); APPLET="${2:-volume}"
prepare
cp "$HOME/.config/plasmashellrc" "$WORK/cfg/" 2>/dev/null || true  # its [Updates] list skips update scripts
rm -rf "$WORK/cache" "$WORK/state" && mkdir -p "$WORK/cache" "$WORK/state" "$WORK/dbus-services"

if [ "${PANEL:-}" = mine ]; then
    cp "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" "$WORK/cfg/"
fi
if [ "$APPLET" = notify ]; then
    [ "${PANEL:-}" = mine ] || cp "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" "$WORK/cfg/"
    cp "$HOME/.config/plasmanotifyrc" "$WORK/cfg/" 2>/dev/null || true
elif [ "${PANEL:-}" = mine ]; then
    # the tray applet's group, e.g. [Containments][4][Applets][9][Applets][12]: give it a shortcut
    group=$(awk -v p="plugin=org.kde.plasma.$APPLET" '/^\[/{h=$0} $0 == p && h ~ /\]\[Applets\]\[[0-9]+\]\[Applets\]\[[0-9]+\]$/{print h; exit}' \
            "$WORK/cfg/plasma-org.kde.plasma.desktop-appletsrc")
    [ -n "$group" ] || die "no org.kde.plasma.$APPLET in your system tray"
    id=$(echo "$group" | sed 's/.*\[\([0-9]*\)\]$/\1/')
    # shellcheck disable=SC2046
    kwriteconfig6 --file "$WORK/cfg/plasma-org.kde.plasma.desktop-appletsrc" \
        $(echo "$group" | tr -d '[' | tr ']' '\n' | sed '/^$/d; s/^/--group /') --group Shortcuts --key global Meta+Ctrl+Alt+F11
else
    case "$APPLET" in
        volume) id=4 ;;
        clipboard) id=5 ;;
        *) die "the generated panel only has volume and clipboard (PANEL=mine for your tray)" ;;
    esac
# Every applet counts as known, so the tray adds nothing beyond volume and clipboard.
plugins=$( { ls /usr/lib64/qt6/plugins/plasma/applets/ | sed 's/\.so$//'; ls /usr/share/plasma/plasmoids/ "$HOME/.local/share/plasma/plasmoids/" 2>/dev/null; } \
          | grep '^[a-z]' | sort -u | paste -sd, -)
cat >"$WORK/cfg/plasma-org.kde.plasma.desktop-appletsrc" <<CFG
[Containments][1]
activityId=
formfactor=0
immutability=1
lastScreen=0
location=0
plugin=org.kde.desktopcontainment
wallpaperplugin=org.kde.image

[Containments][1][Wallpaper][org.kde.image][General]
Image=file://$WALLPAPER_FILE

[Containments][2]
activityId=
formfactor=2
immutability=1
lastScreen=0
location=4
plugin=org.kde.panel
wallpaperplugin=org.kde.image

[Containments][2][Applets][3]
immutability=1
plugin=org.kde.plasma.systemtray

[Containments][2][Applets][3][Applets][4]
immutability=1
plugin=org.kde.plasma.volume

[Containments][2][Applets][3][Applets][4][Shortcuts]
global=Meta+Ctrl+Alt+F11

[Containments][2][Applets][3][Applets][5]
immutability=1
plugin=org.kde.plasma.clipboard

[Containments][2][Applets][3][Applets][5][Shortcuts]
global=Meta+Ctrl+Alt+F12

[Containments][2][Applets][3][General]
extraItems=org.kde.plasma.volume,org.kde.plasma.clipboard
knownItems=$plugins

[Containments][2][Applets][6]
immutability=1
plugin=org.kde.plasma.panelspacer

[Containments][2][General]
AppletOrder=6;3
CFG
# the panel floats (or not) and is as thick as your first panel, since popups from a floating panel keep
# all their borders; a spacer puts the tray at its right end, as usual
floating=$(sed -n 's/^floating=//p' "$HOME/.config/plasmashellrc" 2>/dev/null | head -1)
thickness=$(sed -n 's/^thickness=//p' "$HOME/.config/plasmashellrc" 2>/dev/null | head -1)
kwriteconfig6 --file "$WORK/cfg/plasmashellrc" --group PlasmaViews --group "Panel 2" --key floating "${floating:-1}"
kwriteconfig6 --file "$WORK/cfg/plasmashellrc" --group PlasmaViews --group "Panel 2" --group Defaults --key thickness "${thickness:-44}"
fi

# A private bus that can only start the activity manager (plasmashell waits for it).
for s in org.kde.ActivityManager; do
    ln -sf "/usr/share/dbus-1/services/$s.service" "$WORK/dbus-services/"
done
cat >"$WORK/dbus.conf" <<CFG
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <servicedir>$WORK/dbus-services</servicedir>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
CFG

DBUS_CONFIG="$WORK/dbus.conf" XDG_CACHE_HOME="$WORK/cache" XDG_STATE_HOME="$WORK/state" \
    run_session popup "$([ "$APPLET" = notify ] && echo notify || echo "activate widget $id")"
# QML warnings while plasmashell ran, then the ones it logged while quitting (full log: $WORK/app.log)
pattern='Binding loop|TypeError|ReferenceError|\.qml:[0-9]+'
running=$(grep -E "$pattern" "$WORK/app-running.log" || true)
quitting=$(grep -vxFf "$WORK/app-running.log" "$WORK/app.log" | grep -E "$pattern" || true)
echo "plasmashell warnings while running:"; echo "${running:-none}" | sed 's/^/  /'
echo "plasmashell warnings while quitting:"; echo "${quitting:-none}" | sed 's/^/  /'
crop_to_changes "$OUT"
