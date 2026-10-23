#!/bin/sh
# Runs inside dbus-run-session (see common.sh): virtual KWin, wallpaper, then the app under test.
# Leaves shots/bg.png (before the app shows) and shots/app.png (with it) in $WORK.
#   session.sh krunner QUERY   (HOVER_INPUT: fakeinput commands sent once the results are in, after HOLD s, 8)
#   session.sh dialog
#   session.sh popup ACTION    plasmashell with popup.sh's config, then a plasmashell shortcut action
#   session.sh panel float|dock|record  plasmashell with panel.sh's config and an ordinary window in the
#                              middle: as it is, or with the window maximized (a floating panel docks), or
#                              recorded (PANEL_AREA) for SECONDS_CAPTURED while the window maximizes MAX_AT s
#                              in and is restored RESTORE_AT s in, into record.mkv
#   session.sh unfold QUERY    KRunner; capture frames while results for QUERY unfold, then fold
#   session.sh drag QUERY      KRunner with results for QUERY, then FAKEINPUT < DRAG_INPUT, while a KWin
#                              script logs KRunner's frame geometry and output (kwin.log, "KRUNNER" lines)
#   session.sh record QUERY    KRunner with results for QUERY, then (HOLD s later, 3) its window recorded for
#                              SECONDS_CAPTURED into record.mkv (frames.py record), HOVER_INPUT sent as it starts
#   session.sh settings KCM [ARGS]  System Settings on page KCM, given ARGS (systemsettings --args), after
#                              2 + HOLD s (4); ARGS2: then sent to the open page as KRunner's results do,
#                              shots/before.png just before
# Any mode: INDEXING="DELAY DURATION" starts a stand-in search service (fake-indexer.py) that reports
# indexing progress for DURATION seconds after DELAY.
MODE="$1"; shift
SOCK="$PREVIEW_SOCK"  # chosen by run_session, which also points the bus's services at it
export XDG_CONFIG_HOME="$WORK/cfg"
# SWITCH: global themes write their settings as defaults, where a Plasma session reads them
[ -z "${SWITCH:-}" ] || export XDG_CONFIG_DIRS="$WORK/cfg/kdedefaults:${XDG_CONFIG_DIRS:-/etc/xdg}"

# Global shortcuts stay off except for plasmashell, whose applet shortcuts open the popups, and System
# Settings, whose Shortcuts page lists them (SHORTCUTS=1: on in any mode, e.g. for KRunner's System
# Settings results, which list them too). Permission checks are off so tools/preview/fakeinput.c may
# send pointer input; this KWin only serves the preview.
shortcuts=--no-global-shortcuts
case "$MODE" in popup|panel|settings) shortcuts= ;; esac
[ -z "${SHORTCUTS:-}" ] || shortcuts=
# KWIN_ENV: extra environment for KWin only, e.g. to composite on another GPU like the real session.
# KWIN_WAYLAND: a dev build of KWin to run instead of the installed one (tools/patch-dev.sh kwin, then
# ninja -C ~/.cache/plasma-glass/dev/kwin/build kwin_wayland)
# shellcheck disable=SC2086
env -u WAYLAND_DISPLAY KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1 ${KWIN_ENV:-} \
    "${KWIN_WAYLAND:-kwin_wayland}" --virtual --width "$WIDTH" --height "$HEIGHT" --scale "$SCALE" --output-count "${OUTPUTS:-1}" --socket "$SOCK" \
    --no-lockscreen $shortcuts >"$WORK/kwin.log" 2>&1 &
KWIN=$!
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
export WAYLAND_DISPLAY="$SOCK" QT_QPA_PLATFORM=wayland
# a Plasma session's own: Qt then loads KDE's platform theme, so apps get your font (kdeglobals; Noto Sans
# 10 pt by default) instead of Qt's generic "Sans Serif" 9 pt
export XDG_CURRENT_DESKTOP=KDE KDE_FULL_SESSION=true KDE_SESSION_VERSION=6
# REFRESH=240000 (mHz): the virtual output runs at that rate instead of 60 Hz, through a custom mode
if [ -n "${REFRESH:-}" ]; then
    kscreen-doctor "output.Virtual-0.addCustomMode.$WIDTH.$HEIGHT.$REFRESH.full" >"$WORK/kscreen.log" 2>&1
    kscreen-doctor "output.Virtual-0.mode.${WIDTH}x${HEIGHT}@$((REFRESH / 1000))" >>"$WORK/kscreen.log" 2>&1
    kscreen-doctor -o 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Output|Modes' | cut -c1-160 >>"$WORK/kscreen.log"
fi

if [ "$MODE" != popup ] && [ "$MODE" != panel ]; then  # plasmashell draws its own wallpaper
    # WALLPAPER_PAN=px/s: it scrolls up and down behind KRunner (record.sh; screenshots crop to everything)
    qml6 "$HERE/qml/wallpaper.qml" -- "$WALLPAPER_FILE" ${WALLPAPER_PAN:+"$WALLPAPER_PAN"} >"$WORK/wallpaper.log" 2>&1 &
    sleep 1.5
    spectacle -b -n -f -o "$WORK/shots/bg.png" >/dev/null 2>&1
fi

# INDEXING="DELAY DURATION": a stand-in for the search service reports indexing progress
if [ -n "${INDEXING:-}" ]; then
    # shellcheck disable=SC2086
    "$TOOL_PYTHON" -I "$HERE/fake-indexer.py" $INDEXING >"$WORK/indexer.log" 2>&1 &
    sleep 0.5
fi

case "$MODE" in
    krunner)
        # SWITCH="FROM TO": KRunner starts on global theme FROM, and TO is applied once the results are in
        [ -z "${SWITCH:-}" ] || plasma-apply-lookandfeel --apply "${SWITCH% *}" >"$WORK/switch.log" 2>&1
        env ${KRUNNER_ENV:-} "${KRUNNER:-krunner}" >"$WORK/app.log" 2>&1 &  # KRUNNER: a dev build (tools/patch-dev.sh krunner)
        sleep 2
        qdbus6 org.kde.krunner /App org.kde.krunner.App.query "$1"
        sleep "${HOLD:-8}"  # let results arrive (the semantic search service can be slow while the CPU is busy)
        if [ -n "${HOVER_INPUT:-}" ]; then  # then the pointer over a row, long enough for its tooltip
            "$FAKEINPUT" <"$HOVER_INPUT"; sleep 2
        fi
        if [ -n "${SESSION_HOOK:-}" ]; then  # a script to run in the session now (effect.sh's swaps), before.png first
            spectacle -b -n -f -o "$WORK/shots/before.png" >/dev/null 2>&1
            sh "$SESSION_HOOK" >"$WORK/hook.log" 2>&1 || echo "hook failed" >>"$WORK/hook.log"
            sleep 1
        fi
        if [ -n "${SWITCH:-}" ]; then
            spectacle -b -n -f -o "$WORK/shots/before.png" >/dev/null 2>&1
            plasma-apply-lookandfeel --apply "${SWITCH#* }" >>"$WORK/switch.log" 2>&1
            sleep 4  # the style follows 0.1 s after the config change, the colours later
        fi
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
    record)
        # shellcheck disable=SC2086
        env ${KRUNNER_ENV:-} "${KRUNNER:-krunner}" >"$WORK/app.log" 2>&1 &
        sleep 2
        # QUERY2: the recording starts on QUERY and this one follows QUERY2_AT s in (default 2); the
        # window is measured with its results, so the recording takes in the larger of the two
        qdbus6 org.kde.krunner /App org.kde.krunner.App.query "${QUERY2:-$1}"
        sleep "${HOLD:-3}"  # results arrive and unfold
        cat >"$WORK/where.js" <<'JS'
for (const w of workspace.windowList())
    if (String(w.resourceClass).indexOf("krunner") >= 0)
        console.info("KRUNNER", JSON.stringify(w.frameGeometry));
JS
        id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$WORK/where.js" preview-where)
        qdbus6 org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
        sleep 0.5
        if [ -n "${QUERY2:-}" ]; then
            qdbus6 org.kde.krunner /App org.kde.krunner.App.query "$1"
            sleep 2  # the results change or fold away
        fi
        "$TOOL_PYTHON" -I "$HERE/frames.py" record "$WORK/record.mkv" "${SECONDS_CAPTURED:-6}" \
            "$(grep KRUNNER "$WORK/kwin.log" | tail -1)" >"$WORK/grab.log" 2>&1 &
        REC=$!
        if [ -n "${QUERY2:-}" ]; then
            sleep "${QUERY2_AT:-2}"; qdbus6 org.kde.krunner /App org.kde.krunner.App.query "$QUERY2"
        fi
        if [ -n "${HOVER_INPUT:-}" ]; then "$FAKEINPUT" <"$HOVER_INPUT" & fi  # pointer moves while recording
        wait $REC
        ;;
    settings)
        # SYSTEMSETTINGS_ENV: its environment, e.g. QT_PLUGIN_PATH=$(tools/patch-dev.sh kcm-keys) to load a
        # dev build of the Shortcuts page
        # shellcheck disable=SC2086
        env ${SYSTEMSETTINGS_ENV:-} systemsettings "$1" ${2:+--args "$2"} >"$WORK/app.log" 2>&1 &
        sleep 2
        # the size it opens at with no saved one is cramped: 1240x760 logical px, centred
        cat >"$WORK/size.js" <<JS
for (const w of workspace.windowList())
    if (String(w.resourceClass).indexOf("systemsettings") >= 0)
        w.frameGeometry = {x: ($WIDTH / $SCALE - 1240) / 2, y: ($HEIGHT / $SCALE - 760) / 2, width: 1240, height: 760};
JS
        id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$WORK/size.js" preview-size)
        qdbus6 org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
        sleep "${HOLD:-4}"
        if [ -n "${ARGS2:-}" ]; then  # a second systemsettings hands its arguments to the open one and exits
            spectacle -b -n -f -o "$WORK/shots/before.png" >/dev/null 2>&1
            # shellcheck disable=SC2086
            env ${SYSTEMSETTINGS_ENV:-} systemsettings "$1" --args "$ARGS2" >>"$WORK/app.log" 2>&1
            sleep 3
        fi
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
    panel)
        "${PLASMASHELL:-plasmashell}" --no-respawn >"$WORK/app.log" 2>&1 &
        SHELL_PID=$!
        for _ in $(seq 100); do qdbus6 org.kde.plasmashell >/dev/null 2>&1 && break; sleep 0.1; done
        sleep 6  # panel, wallpaper and applets
        # an ordinary window, placed clear of the panel: maximized, it touches it, and a floating panel docks
        qml6 "$HERE/qml/window.qml" -- "${WINDOW_COLOR:-#2a2e32}" >"$WORK/window.log" 2>&1 &  # panel.sh's WINDOW_COLOR
        sleep 1.5
        maximize() {  # true: maximize the preview window; false: restore it
            cat >"$WORK/maximize.js" <<JS
for (const w of workspace.windowList())
    if (w.caption === "Preview window") w.setMaximize($1, $1);
JS
            id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$WORK/maximize.js" "preview-maximize-$(date +%s%N)")
            qdbus6 org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
        }
        case "$1" in
            dock) maximize true; sleep 2 ;;
            record) if [ -n "${CLICK_INPUT:-}" ] && [ "${DOCK:-0}" = 1 ]; then maximize true; sleep 2; fi ;;
        esac
        if [ -n "${POPUP_ID:-}" ] && [ -z "${POPUP_AT:-}" ] && { [ "$1" != record ] || [ -n "${CLICK_INPUT:-}" ]; }; then  # panel.sh's POPUP
            qdbus6 org.kde.kglobalaccel /component/plasmashell org.kde.kglobalaccel.Component.invokeShortcut \
                "activate widget $POPUP_ID" || echo "could not open widget $POPUP_ID" >&2
            sleep 2
        fi
        case "$1" in
            record)
                "$TOOL_PYTHON" -I "$HERE/frames.py" record "$WORK/record.mkv" "$SECONDS_CAPTURED" "PANEL $PANEL_AREA" \
                    >"$WORK/grab.log" 2>&1 &
                REC=$!
                if [ -n "${POPUP_AT:-}" ]; then  # panel.sh's POPUP_AT: the popup opens and closes then
                    last=0
                    for at in $POPUP_AT; do
                        sleep "$(awk "BEGIN{print $at - $last}")"; last=$at
                        qdbus6 org.kde.kglobalaccel /component/plasmashell org.kde.kglobalaccel.Component.invokeShortcut \
                            "activate widget $POPUP_ID" >/dev/null 2>&1
                    done
                elif [ -n "${CLICK_INPUT:-}" ]; then  # panel.sh's CLICKS
                    sleep 0.5; "$FAKEINPUT" <"$CLICK_INPUT"
                else
                    sleep "$MAX_AT"; maximize true
                    sleep "$(awk "BEGIN{print $RESTORE_AT - $MAX_AT}")"; maximize false
                fi
                wait $REC
                ;;
        esac
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
