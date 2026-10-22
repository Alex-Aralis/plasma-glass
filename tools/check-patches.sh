#!/bin/sh
# Checks the Portage patches before a long rebuild (about 10 s, no compiling, nothing on screen):
#   1. each patch applies to the source of the installed package version, alone and together with the
#      other user patches in /etc/portage/patches for that package (kde-fixes'), in Portage's order
#   2. the patched QML loads under Qt, with stubs for modules that only exist inside krunner or
#      plasmashell (this catches errors that only show at runtime, like assigning to a grouped property)
#   3. patched KRunner C++ passes a compiler syntax check (KWin's, plasmashell's and the Shortcuts page's need
#      their build trees' generated headers: `tools/patch-dev.sh kwin`, `plasmashell` and `kcm-keys` compile them)
# Needs the source tarballs in Portage's DISTDIR (kept after a build; otherwise `emerge --fetchonly
# kde-plasma/plasma-workspace kde-plasma/milou kde-plasma/kwin kde-plasma/plasma-desktop`). Exit status 1
# on any failure.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
DISTDIR=$(portageq envvar DISTDIR 2>/dev/null || echo /var/cache/distfiles)
FAILED=0

ok() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILED=1; }
note() { printf '  --    %s\n' "$*"; }

# apply DIR PATCH: as Portage's eapply_user does
apply() { patch -p1 -f -s -g0 --no-backup-if-mismatch -d "$1" < "$2" >"$WORK/patch.log" 2>&1; }

# others CATEGORY/PKG: the other user patches Portage applies to PKG with ours (kde-fixes'), from its
# directory in /etc/portage/patches, without our own names (and our patches' old names, which the
# installers remove: kwin-fixes.patch until 2026-10-17, kwin-liquid-glass.patch and
# plasma-desktop-shortcut-search.patch until 2026-10-22)
others() {
    for f in /etc/portage/patches/$1/*; do
        case "$(basename "$f")" in kwin-fixes.patch|kwin-liquid-glass.patch|plasma-desktop-shortcut-search.patch) continue ;; esac
        [ -e "$REPO/patches/$1/$(basename "$f")" ] && continue
        case "$f" in *.patch|*.diff) if [ -f "$f" ]; then echo "$f"; fi ;; esac
    done
}

# prepare CATEGORY/PKG : extract the parts of the installed version's source the patches touch, apply
# ours, then everything Portage will apply (ours and the others, by file name) in a copy. Writes the
# patched source dir to $WORK/PKG.dir, or nothing if ours don't apply.
prepare() {
    cat=${1%/*} pkg=${1#*/}
    patches=$(ls "$REPO/patches/$cat/$pkg/"*.patch 2>/dev/null) || return 0
    ver=$(portageq best_version / "$cat/$pkg" 2>/dev/null | sed -E "s|^$cat/$pkg-||; s|-r[0-9]+$||")
    [ -n "$ver" ] || { bad "$pkg is not installed"; return 0; }
    top=$pkg-$ver
    tarball="$DISTDIR/$top.tar.xz"
    [ -f "$tarball" ] || { bad "$top source not in $DISTDIR (emerge --fetchonly $cat/$pkg)"; return 0; }
    other=$(others "$1")
    # whole directories around the patched files, since QML resolves sibling files and C++ includes them
    # shellcheck disable=SC2086
    dirs=$(cat $patches $other | sed -n 's|^+++ b/||p' | awk -F/ '{
        if ($1 == "applets" && NF > 2) print $1 "/" $2
        else if ($1 == "src") { n = (NF - 1 < 4) ? NF - 1 : 4; d = $1; for (i = 2; i <= n; i++) d = d "/" $i; print d }
        else print $1 }' | sort -u \
        | awk '{ for (i = 1; i <= n; i++) if (index($0 "/", d[i] "/") == 1) next; d[++n] = $0; print }')
    # (without the ones inside another: tar reports a name it already extracted under its parent as missing)
    # one pass over the tarball (xz has to be decompressed in full each time)
    # shellcheck disable=SC2046
    tar -xJf "$tarball" -C "$WORK" $(for d in $dirs; do echo "$top/$d"; done)
    [ -z "$other" ] || cp -a "$WORK/$top" "$WORK/$pkg.all"
    for p in $patches; do
        if apply "$WORK/$top" "$p"; then
            ok "$(basename "$p") applies to $pkg $ver"
        else
            bad "$(basename "$p") does not apply to $pkg $ver: $(head -3 "$WORK/patch.log" | tr '\n' ' ')"
            return 0
        fi
    done
    echo "$WORK/$top" > "$WORK/$pkg.dir"
    [ -n "$other" ] || return 0
    names=$(for p in $other; do basename "$p"; done | tr '\n' ' ' | sed 's/ $//') applied=""
    # shellcheck disable=SC2086
    for p in $(for p in $patches $other; do printf '%s\t%s\n' "$(basename "$p")" "$p"; done | LC_ALL=C sort | cut -f2); do
        if ! apply "$WORK/$pkg.all" "$p"; then
            bad "with the other patches in /etc/portage/patches/$cat/$pkg ($names): $(basename "$p") does not apply after ${applied% }"
            return 0
        fi
        applied="$applied$(basename "$p") "
    done
    ok "together with $names (in Portage's order: ${applied% })"
    echo "$WORK/$pkg.all" > "$WORK/$pkg.dir"
}

# Stub QML modules standing in for C++ types that krunner/plasmashell (and the Shortcuts page) register at
# runtime.
STUBS="$WORK/stubs"
mkdir -p "$STUBS/org/kde/krunner/private/view" "$STUBS/plasma/applet/org/kde/plasma/notifications" "$STUBS/org/kde/private/kcms/keys"
printf 'module org.kde.private.kcms.keys\nBaseModel 2.0 BaseModel.qml\n' > "$STUBS/org/kde/private/kcms/keys/qmldir"
printf 'import QtQuick\nQtObject {}\n' > "$STUBS/org/kde/private/kcms/keys/BaseModel.qml"
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
    property bool changingScreen: false
    property real bottomPadding: 12
    property real indexingProgress: -1
    property bool busyDemo: false
    property var liquidGlass: ({})
    property bool tuning: false
    signal activityChanged(string activity)
    signal showHistoryChanged()
    function startFloatingDrag(x, y) {}
    function endFloatingDrag(x, y) {}
    function stir(busy, side, at) {}
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
prepare kde-plasma/plasma-workspace
prepare kde-plasma/milou
prepare kde-plasma/kwin
prepare kde-plasma/plasma-desktop
PW=$(cat "$WORK/plasma-workspace.dir" 2>/dev/null || true)
MI=$(cat "$WORK/milou.dir" 2>/dev/null || true)
PD=$(cat "$WORK/plasma-desktop.dir" 2>/dev/null || true)

echo "QML"
if [ -n "$PW" ]; then
    load_qml "KRunner RunCommand.qml" "$PW/krunner/qml/RunCommand.qml" krunner
    # needs a real notification model to instantiate, so compile only
    load_qml "notifications HeadingButtons.qml" "$PW/applets/notifications/components/HeadingButtons.qml" compile
    # the popup window (with DraggableDelegate and the popup delegate) needs plasmashell to run; compile it
    load_qml "notifications NotificationPopup.qml" "$PW/applets/notifications/NotificationPopup.qml" compile
    load_qml "notifications DelegatePopup.qml" "$PW/applets/notifications/delegates/DelegatePopup.qml" compile
fi
[ -n "$MI" ] && load_qml "milou ResultsView.qml (+ ResultDelegate.qml)" "$MI/lib/ResultsView.qml"
# needs the page's C++ (the kcm object, its models) to instantiate, so compile only
[ -n "$PD" ] && load_qml "Shortcuts page main.qml (+ ShortcutActionDelegate.qml)" "$PD/kcms/keys/ui/main.qml" compile

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
