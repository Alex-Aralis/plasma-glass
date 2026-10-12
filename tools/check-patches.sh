#!/bin/sh
# Checks the Plasma patches before a long rebuild (about 10 s, no compiling, nothing on screen):
#   1. each patch applies to the source of the installed package version
#   2. the patched QML loads under Qt, with stubs for modules that only exist inside krunner or
#      plasmashell (this catches errors that only show at runtime, like assigning to a grouped property)
#   3. patched KRunner C++ passes a compiler syntax check
# Needs the source tarballs in Portage's DISTDIR (kept after a build; otherwise
# `emerge --fetchonly kde-plasma/plasma-workspace kde-plasma/milou`). Exit status 1 on any failure.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
DISTDIR=$(portageq envvar DISTDIR 2>/dev/null || echo /var/cache/distfiles)
FAILED=0

ok() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILED=1; }
note() { printf '  --    %s\n' "$*"; }

# prepare PKG : extract the parts of the installed version's source the patches touch, apply them.
# Prints the source dir, or nothing if that failed.
prepare() {
    pkg=$1
    patches=$(ls "$REPO/patches/kde-plasma/$pkg/"*.patch 2>/dev/null) || return 0
    ver=$(portageq best_version / "kde-plasma/$pkg" 2>/dev/null | sed -E "s|^kde-plasma/$pkg-||; s|-r[0-9]+$||")
    [ -n "$ver" ] || { bad "$pkg is not installed"; return 0; }
    tarball="$DISTDIR/$pkg-$ver.tar.xz"
    [ -f "$tarball" ] || { bad "$pkg-$ver source not in $DISTDIR (emerge --fetchonly kde-plasma/$pkg)"; return 0; }
    # whole directories around the patched files, since QML resolves sibling files
    dirs=$(cat $patches | sed -n 's|^+++ b/||p' | awk -F/ '{ print (NF > 2 && $1 == "applets") ? $1 "/" $2 : $1 }' | sort -u)
    # one pass over the tarball (xz has to be decompressed in full each time)
    # shellcheck disable=SC2046
    tar -xJf "$tarball" -C "$WORK" $(for d in $dirs; do echo "$pkg-$ver/$d"; done)
    for p in $patches; do
        if patch -s -p1 -d "$WORK/$pkg-$ver" < "$p" >"$WORK/patch.log" 2>&1; then
            ok "$(basename "$p") applies to $pkg $ver"
        else
            bad "$(basename "$p") does not apply to $pkg $ver: $(head -3 "$WORK/patch.log" | tr '\n' ' ')"
            return 0
        fi
    done
    echo "$WORK/$pkg-$ver" > "$WORK/$pkg.dir"
}

# Stub QML modules standing in for C++ types that krunner/plasmashell register at runtime.
STUBS="$WORK/stubs"
mkdir -p "$STUBS/org/kde/krunner/private/view" "$STUBS/plasma/applet/org/kde/plasma/notifications"
cat > "$STUBS/org/kde/krunner/private/view/qmldir" <<'EOF'
module org.kde.krunner.private.view
RunnerWindow 1.0 RunnerWindow.qml
EOF
cat > "$STUBS/org/kde/krunner/private/view/RunnerWindow.qml" <<'EOF'
import QtQuick
QtObject {
    enum HistoryBehavior { Disabled, CompletionSuggestion, ImmediateCompletion }
    property bool visible: true
    property bool pinned: false
    property bool helpEnabled: false
    property bool retainPriorSearch: true
    property int historyBehavior: 1
    signal activityChanged(string activity)
    signal showHistoryChanged()
    function startFloatingDrag(x, y) {}
    function endFloatingDrag(x, y) {}
}
EOF
cat > "$STUBS/plasma/applet/org/kde/plasma/notifications/qmldir" <<'EOF'
module plasma.applet.org.kde.plasma.notifications
singleton Globals 1.0 Globals.qml
singleton DragHelper 1.0 DragHelper.qml
singleton InputDisabler 1.0 InputDisabler.qml
NotificationWindow 1.0 NotificationWindow.qml
FileInfo 1.0 FileInfo.qml
FileMenu 1.0 FileMenu.qml
Thumbnailer 1.0 Thumbnailer.qml
EOF
N="$STUBS/plasma/applet/org/kde/plasma/notifications"
printf 'pragma Singleton\nimport QtQuick\nQtObject { property bool dragActive; property size dragPixmapSize; function startDrag(p, u, x) {} }\n' > "$N/DragHelper.qml"
printf 'pragma Singleton\nimport QtQuick\nQtObject { function makeTransparentForInput(item) {} }\n' > "$N/InputDisabler.qml"
printf 'import QtQuick\nQtObject { property url url; property var modelInterface; signal actionTriggered(var action) }\n' > "$N/FileInfo.qml"
printf 'import QtQuick\nQtObject { property url url; property var visualParent; property bool visible; signal actionTriggered(var action); function open(x, y) {} }\n' > "$N/FileMenu.qml"
printf 'import QtQuick\nQtObject { property url url; property size size }\n' > "$N/Thumbnailer.qml"
printf 'pragma Singleton\nimport QtQuick\nQtObject {}\n' > "$STUBS/plasma/applet/org/kde/plasma/notifications/Globals.qml"
# the popup's C++ base (PlasmaQuick::PlasmaWindow + NotificationWindow): just the members QML sets or reads
cat > "$STUBS/plasma/applet/org/kde/plasma/notifications/NotificationWindow.qml" <<'EOF'
import QtQuick
import QtQuick.Window
Window {
    property Item mainItem
    property bool takeFocus
    property bool isCritical
    property int leftPadding
    property int topPadding
    property int rightPadding
    property int bottomPadding
}
EOF
cat > "$WORK/load.qml" <<'EOF'
import QtQuick
import org.kde.krunner.private.view
// usage: qml6 load.qml -- FILE [krunner|plain|compile]
// "compile" stops once the component is Ready: enough to catch structural errors (which surface at this
// stage), for components that can't be instantiated outside their real host.
Item {
    RunnerWindow { id: rw }
    Component.onCompleted: {
        const args = Qt.application.arguments.slice(Qt.application.arguments.indexOf("--") + 1);
        const c = Qt.createComponent("file://" + args[0]);
        if (c.status !== Component.Ready) { console.info("RESULT FAIL " + c.errorString().replace(/\n/g, " ")); Qt.quit(); return; }
        if (args[1] === "compile") { console.info("RESULT OK"); Qt.quit(); return; }
        const props = args[1] === "krunner" ? { runnerWindow: rw } : {};
        const o = c.createObject(this, props);
        console.info(o ? "RESULT OK" : "RESULT FAIL " + c.errorString().replace(/\n/g, " "));
        Qt.quit();
    }
}
EOF

# load_qml LABEL FILE [props] : does the file load as a component?
load_qml() {
    out=$(QML_IMPORT_PATH="$STUBS" QT_QPA_PLATFORM=offscreen timeout 30 qml6 "$WORK/load.qml" -- "$2" "${3:-plain}" 2>&1 \
          | sed -n 's/.*RESULT //p' | head -1)
    case "$out" in
        OK) [ "${3:-}" = compile ] && ok "$1 compiles" || ok "$1 loads" ;;
        "") bad "$1: qml6 gave no result" ;;
        *) bad "$1: ${out#FAIL }" ;;
    esac
}

echo "Patches"
prepare plasma-workspace
prepare milou
PW=$(cat "$WORK/plasma-workspace.dir" 2>/dev/null || true)
MI=$(cat "$WORK/milou.dir" 2>/dev/null || true)

echo "QML"
if [ -n "$PW" ]; then
    load_qml "KRunner RunCommand.qml" "$PW/krunner/qml/RunCommand.qml" krunner
    load_qml "notifications Body.qml" "$PW/applets/notifications/components/Body.qml"
    # needs a real notification model to instantiate, so compile only
    load_qml "notifications HeadingButtons.qml" "$PW/applets/notifications/components/HeadingButtons.qml" compile
    # the popup window (with DraggableDelegate and the popup delegate) needs plasmashell to run; compile it
    load_qml "notifications NotificationPopup.qml" "$PW/applets/notifications/NotificationPopup.qml" compile
fi
[ -n "$MI" ] && load_qml "milou ResultsView.qml (+ ResultDelegate.qml)" "$MI/lib/ResultsView.qml"

echo "C++"
if [ -n "$PW" ] && [ -f "$PW/krunner/view.cpp" ]; then
    mkdir -p "$WORK/cxxstub"
    printf '#pragma once\n#include <QtDBus>\nclass AppAdaptor : public QDBusAbstractAdaptor { public: explicit AppAdaptor(QObject *o) : QDBusAbstractAdaptor(o) {} };\n' > "$WORK/cxxstub/appadaptor.h"
    : > "$WORK/cxxstub/moc_view.cpp"
    # Wayland protocol code CMake would generate (relative pointer, for dragging the window)
    for xml in "$PW"/krunner/*.xml; do
        [ -f "$xml" ] || continue
        name=$(basename "$xml" .xml)
        wayland-scanner client-header "$xml" "$WORK/cxxstub/wayland-$name-client-protocol.h"
        /usr/lib64/qt6/libexec/qtwaylandscanner client-header "$xml" > "$WORK/cxxstub/qwayland-$name.h"
    done
    kf=$(ls -d /usr/include/KF6/* 2>/dev/null | sed 's/^/-I/' | tr '\n' ' ')
    extra=$(find /usr/include -maxdepth 2 -type d \( -name PlasmaActivities -o -name PlasmaQuick -o -name Plasma -o -name LayerShellQt \) 2>/dev/null \
            | sed 's|/[^/]*$||' | sort -u | sed 's/^/-I/' | tr '\n' ' ')
    qt=$(pkg-config --cflags Qt6Quick Qt6Qml Qt6DBus Qt6Gui Qt6Widgets Qt6WaylandClient wayland-client 2>/dev/null)
    # shellcheck disable=SC2086
    if (cd "$PW/krunner" && g++ -std=c++20 -fsyntax-only -fPIC -I. -I"$WORK/cxxstub" $qt $kf $extra -I/usr/include/LayerShellQt \
            -DQT_NO_CAST_FROM_ASCII view.cpp) >"$WORK/cxx.log" 2>&1; then
        ok "KRunner view.cpp compiles (syntax check)"
    else
        bad "KRunner view.cpp: $(grep -m3 'error' "$WORK/cxx.log" | tr '\n' ' ')"
    fi
fi

echo
if [ "$FAILED" = 0 ]; then echo "All checks passed."; else echo "Some checks failed; fix the patches before rebuilding."; exit 1; fi
