#!/bin/sh
# Runs inside dbus-run-session (see common.sh): virtual KWin, wallpaper, then the app under test.
# Leaves shots/bg.png (wallpaper only) and shots/app.png (with the app) in $WORK.
#   session.sh krunner QUERY
#   session.sh dialog
MODE="$1"; shift
SOCK="$PREVIEW_SOCK"  # chosen by run_session, which also points the bus's services at it
export XDG_CONFIG_HOME="$WORK/cfg"

env -u WAYLAND_DISPLAY kwin_wayland --virtual --width "$WIDTH" --height "$HEIGHT" --scale "$SCALE" --socket "$SOCK" \
    --no-lockscreen --no-global-shortcuts >"$WORK/kwin.log" 2>&1 &
KWIN=$!
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
export WAYLAND_DISPLAY="$SOCK" QT_QPA_PLATFORM=wayland

qml6 "$HERE/qml/wallpaper.qml" -- "$WALLPAPER_FILE" >"$WORK/wallpaper.log" 2>&1 &
sleep 1.5
spectacle -b -n -f -o "$WORK/shots/bg.png" >/dev/null 2>&1

case "$MODE" in
    krunner)
        krunner >"$WORK/app.log" 2>&1 &
        sleep 2
        qdbus6 org.kde.krunner /App org.kde.krunner.App.query "$1"
        sleep 8  # let results arrive (the semantic search service can be slow while the CPU is busy)
        ;;
    dialog)
        qml6 "$HERE/qml/dialog.qml" >"$WORK/app.log" 2>&1 &
        sleep 2
        # A plain qml6 client can't place a Plasma dialog (that needs KWin's plasma-shell protocol,
        # which only Plasma's own apps may use), so it opens at the top-left, where Plasma also leaves
        # out the top and left frame edges. Move it into view with a KWin script; the right and
        # bottom edges, padding and content are accurate. KRunner places itself and shows all edges.
        cat >"$WORK/move.js" <<'JS'
for (const w of workspace.windowList())
    if (String(w.resourceClass).indexOf("qml") >= 0 && !w.fullScreen)  // the dialog, not the wallpaper
        w.frameGeometry = {x: 400, y: 260, width: w.frameGeometry.width, height: w.frameGeometry.height};
JS
        id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$WORK/move.js" preview-move)
        qdbus6 org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
        sleep 1.5
        ;;
esac
spectacle -b -n -f -o "$WORK/shots/app.png" >/dev/null 2>&1

kill $KWIN 2>/dev/null
# Services activated on this private bus (portals, keyring, activity manager...) outlive it unless
# stopped; stop every process attached to it except this script and its caller.
for pid in $(pgrep -u "$(id -u)"); do
    { [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; } && continue
    { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null | grep -qxF "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" \
        && kill "$pid" 2>/dev/null
done
exit 0
