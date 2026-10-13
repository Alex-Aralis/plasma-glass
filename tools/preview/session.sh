#!/bin/sh
# Runs inside dbus-run-session (see common.sh): virtual KWin, wallpaper, then the app under test.
# Leaves shots/bg.png (before the app shows) and shots/app.png (with it) in $WORK.
#   session.sh krunner QUERY
#   session.sh dialog
#   session.sh popup ACTION    plasmashell with popup.sh's config, then a plasmashell shortcut action
#   session.sh unfold QUERY    KRunner; capture frames while results for QUERY unfold, then fold
#   session.sh drag QUERY      KRunner with results for QUERY, then FAKEINPUT < DRAG_INPUT, while a KWin
#                              script logs KRunner's frame geometry and output (kwin.log, "KRUNNER" lines)
MODE="$1"; shift
SOCK="$PREVIEW_SOCK"  # chosen by run_session, which also points the bus's services at it
export XDG_CONFIG_HOME="$WORK/cfg"

# Global shortcuts stay off except for plasmashell, whose applet shortcuts open the popups. Permission
# checks are off so tools/preview/fakeinput.c may send pointer input; this KWin only serves the preview.
shortcuts=--no-global-shortcuts
[ "$MODE" = popup ] && shortcuts=
# KWIN_ENV: extra environment for KWin only, e.g. to composite on another GPU like the real session
# shellcheck disable=SC2086
env -u WAYLAND_DISPLAY KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1 ${KWIN_ENV:-} \
    kwin_wayland --virtual --width "$WIDTH" --height "$HEIGHT" --scale "$SCALE" --output-count "${OUTPUTS:-1}" --socket "$SOCK" \
    --no-lockscreen $shortcuts >"$WORK/kwin.log" 2>&1 &
KWIN=$!
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
export WAYLAND_DISPLAY="$SOCK" QT_QPA_PLATFORM=wayland
# REFRESH=240000 (mHz): the virtual output runs at that rate instead of 60 Hz, through a custom mode
if [ -n "${REFRESH:-}" ]; then
    kscreen-doctor "output.Virtual-0.addCustomMode.$WIDTH.$HEIGHT.$REFRESH.full" >"$WORK/kscreen.log" 2>&1
    kscreen-doctor "output.Virtual-0.mode.${WIDTH}x${HEIGHT}@$((REFRESH / 1000))" >>"$WORK/kscreen.log" 2>&1
    kscreen-doctor -o 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Output|Modes' | cut -c1-160 >>"$WORK/kscreen.log"
fi

if [ "$MODE" != popup ]; then  # plasmashell draws its own wallpaper
    qml6 "$HERE/qml/wallpaper.qml" -- "$WALLPAPER_FILE" >"$WORK/wallpaper.log" 2>&1 &
    sleep 1.5
    spectacle -b -n -f -o "$WORK/shots/bg.png" >/dev/null 2>&1
fi

case "$MODE" in
    krunner)
        "${KRUNNER:-krunner}" >"$WORK/app.log" 2>&1 &  # KRUNNER: a dev build (tools/patch-dev.sh krunner)
        sleep 2
        qdbus6 org.kde.krunner /App org.kde.krunner.App.query "$1"
        sleep 8  # let results arrive (the semantic search service can be slow while the CPU is busy)
        ;;
    dialog)
        qml6 "${DIALOG_QML:-$HERE/qml/dialog.qml}" >"$WORK/app.log" 2>&1 &  # DIALOG_QML: another dialog to show
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
    drag)
        # shellcheck disable=SC2086
        env ${KRUNNER_ENV:-} "${KRUNNER:-krunner}" >"$WORK/app.log" 2>&1 &
        sleep 2
        qdbus6 org.kde.krunner /App org.kde.krunner.App.query "$1"
        sleep 3
        cat >"$WORK/track.js" <<'JS'
function track(w) {
    if (String(w.resourceClass).indexOf("krunner") < 0) return;
    const log = () => console.info("KRUNNER", w.output ? w.output.name : "-", JSON.stringify(w.frameGeometry));
    log();
    w.frameGeometryChanged.connect(log);
    w.outputChanged.connect(log);
}
workspace.windowList().forEach(track);
workspace.windowAdded.connect(track);
JS
        id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$WORK/track.js" preview-track)
        qdbus6 org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
        "$FAKEINPUT" <"$DRAG_INPUT"
        sleep 1.5
        if [ -n "${REOPEN:-}" ]; then  # close and open it again: does it come back where it was left?
            qdbus6 org.kde.krunner /App org.kde.krunner.App.toggleDisplay
            echo "active output at reopen: $(qdbus6 org.kde.KWin /KWin org.kde.KWin.activeOutputName)" >"$WORK/reopen.log"
            sleep 1
            qdbus6 org.kde.krunner /App org.kde.krunner.App.display
            sleep 1.5
        fi
        ;;
    unfold)
        # shellcheck disable=SC2086
        env ${KRUNNER_ENV:-} "${KRUNNER:-krunner}" >"$WORK/app.log" 2>&1 &
        sleep 2
        qdbus6 org.kde.krunner /App org.kde.krunner.App.display
        sleep 1.5
        "$TOOL_PYTHON" -I "$HERE/frames.py" grab "$WORK/frames" "${SECONDS_CAPTURED:-2.6}" >"$WORK/grab.log" 2>&1 &
        GRAB=$!
        if [ -n "${TYPE_INPUT:-}" ]; then  # typed instead: fakeinput commands (keys) from this file
            sleep 0.3; "$FAKEINPUT" <"$TYPE_INPUT"
        else
            sleep 0.3; qdbus6 org.kde.krunner /App org.kde.krunner.App.query "$1"
            sleep 1.2; qdbus6 org.kde.krunner /App org.kde.krunner.App.query "${QUERY2:-}"  # QUERY2: then this query
        fi
        wait $GRAB
        ;;
    popup)
        plasmashell --no-respawn >"$WORK/app.log" 2>&1 &
        SHELL_PID=$!
        for _ in $(seq 100); do qdbus6 org.kde.plasmashell >/dev/null 2>&1 && break; sleep 0.1; done
        sleep 6  # panel, tray and the popups plasmashell preloads
        spectacle -b -n -f -o "$WORK/shots/bg.png" >/dev/null 2>&1
        if [ "$1" = notify ]; then  # the sample notifications from desktop/test-notifications.sh
            sh "$HERE/../../desktop/test-notifications.sh" all
            sleep 3
        else
            qdbus6 org.kde.kglobalaccel /component/plasmashell org.kde.kglobalaccel.Component.invokeShortcut "$1" \
                || echo "could not invoke '$1'" >&2
            sleep 2
        fi
        ;;
esac
spectacle -b -n -f -o "$WORK/shots/app.png" >/dev/null 2>&1
cp "$WORK/app.log" "$WORK/app-running.log"  # what the app logged before it was asked to quit

# Services activated on this private bus (portals, keyring, activity manager...) outlive it unless
# stopped, so stop every process attached to it except KWin, this script and its caller. Then KWin,
# with SIGKILL: the virtual KWin segfaults on SIGTERM, and each crash starts DrKonqi on your real
# desktop.
for pid in $(pgrep -u "$(id -u)"); do
    { [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || [ "$pid" = "$KWIN" ]; } && continue
    { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null | grep -qxF "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" \
        && kill "$pid" 2>/dev/null
done
[ -z "${SHELL_PID:-}" ] || wait "$SHELL_PID"  # plasmashell logs while it tears down; let it finish
kill -KILL $KWIN 2>/dev/null
wait $KWIN 2>/dev/null
exit 0
