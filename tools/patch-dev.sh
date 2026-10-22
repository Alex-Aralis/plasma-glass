#!/bin/sh
# Work on the Portage patches as plain files instead of hand-editing diffs.
#
#   tools/patch-dev.sh setup [PKG...]  pristine + patched copies of the touched source dirs, for the
#                                installed versions, in ~/.cache/plasma-glass/dev/{a,b}/<package>
#   (edit files under ~/.cache/plasma-glass/dev/b/<package>/...)
#   tools/patch-dev.sh refresh   regenerate patches/<category>/<package>/*.patch from the edits
#   tools/patch-dev.sh check     tools/check-patches.sh (patches apply, QML loads, C++ compiles)
#   tools/patch-dev.sh krunner   build just KRunner from the edited tree (about 10 s once configured) and
#                                print its path; also puts the edited milou QML in ~/.cache/plasma-glass/dev/qml.
#                                Preview with: QML_IMPORT_PATH=~/.cache/plasma-glass/dev/qml \
#                                    KRUNNER=$(tools/patch-dev.sh krunner) tools/preview/krunner.sh OUT.png
#   tools/patch-dev.sh plasmashell  build plasmashell from the edited tree (its shell/; same build tree as
#                                krunner's) and print its path, for the preview: PLASMASHELL=$(...) with
#                                SHELL_PACKAGE=~/.cache/plasma-glass/dev/b/plasma-desktop/desktoppackage
#                                tools/preview/panel.sh OUT.png (the edited Panel.qml)
#   tools/patch-dev.sh kwin      compile the edited KWin files in a KWin tree configured like its ebuild, with
#                                Gentoo's patchset and the other user patches in /etc/portage/patches
#                                (kde-fixes'), to check them before the emerge (a few minutes the first time,
#                                then seconds). The patched KWin only runs after the emerge and a relogin.
#   tools/patch-dev.sh kcm-keys  build System Settings' Shortcuts page (kcm_keys) from the edited tree and
#                                print the folder to run it from (about a minute the first time, then seconds):
#                                    QT_PLUGIN_PATH=$(tools/patch-dev.sh kcm-keys) systemsettings kcm_keys
#   tools/patch-dev.sh install [PKG...]  (root) put the patches in /etc/portage/patches and rebuild the
#                                packages whose patch changed or that weren't rebuilt since (or the PKGs named)
#
# Packages: plasma-workspace, milou, kwin and plasma-desktop (kde-plasma). Each has a single patch file; setup extracts
# whole directories (DIRS below), so any file in them can be edited and refresh picks it up. To touch
# another directory, add it to DIRS and re-run setup. The fixes for KDE and Qt bugs that aren't
# plasma-glass's own (KSvg, Qt, KWin's frame pacing and crash fixes) are in kde-fixes
# (~/Projects/kde-fixes), whose tools/patch-dev.sh also builds patched Qt libraries for the preview.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
DEV="${XDG_CACHE_HOME:-$HOME/.cache}/plasma-glass/dev"
DISTDIR=$(portageq envvar DISTDIR 2>/dev/null || echo /var/cache/distfiles)
PKGS="plasma-workspace milou kwin plasma-desktop"
CAT_plasma_workspace=kde-plasma CAT_milou=kde-plasma CAT_kwin=kde-plasma CAT_plasma_desktop=kde-plasma
DIRS_plasma_workspace="krunner applets/notifications shell"
DIRS_milou="lib"
DIRS_kwin="src"
DIRS_plasma_desktop="kcms/keys desktoppackage"
PATCH_plasma_workspace=plasma-workspace-tweaks.patch
PATCH_milou=milou-section-headers.patch
PATCH_kwin=kwin-liquid-glass.patch
PATCH_plasma_desktop=plasma-desktop-tweaks.patch

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
var() { eval "echo \"\$${1}_$(echo "$2" | tr - _)\""; }

# installed version of PKG without the revision, e.g. 6.11.2
version() {
    cat=$(var CAT "$1")
    portageq best_version / "$cat/$1" 2>/dev/null | sed -E "s|^$cat/$1-||; s|-r[0-9]+$||"
}
srcdir() { echo "$1-$2"; }  # tarball's top dir
patchfile() { echo "$REPO/patches/$(var CAT "$1")/$1/$(var PATCH "$1")"; }

setup() {
    for pkg in ${*:-$PKGS}; do
        ver=$(version "$pkg"); [ -n "$ver" ] || die "$(var CAT "$pkg")/$pkg is not installed"
        top=$(srcdir "$pkg" "$ver")
        tarball="$DISTDIR/$top.tar.xz"
        [ -f "$tarball" ] || die "$tarball missing (emerge --fetchonly $(var CAT "$pkg")/$pkg)"
        if [ -d "$DEV/b/$pkg" ] && [ "${FORCE:-0}" != 1 ]; then
            die "$DEV/b/$pkg exists (FORCE=1 to discard it and start over)"
        fi
        rm -rf "${DEV:?}/a/$pkg" "${DEV:?}/b/$pkg" "${DEV:?}/tmp"
        mkdir -p "$DEV/a/$pkg" "$DEV/b" "$DEV/tmp"
        # shellcheck disable=SC2046
        tar -xJf "$tarball" -C "$DEV/tmp" $(for d in $(var DIRS "$pkg"); do echo "$top/$d"; done)
        cp -r "$DEV/tmp/$top/." "$DEV/a/$pkg/"
        cp -r "$DEV/a/$pkg" "$DEV/b/$pkg"
        if [ -f "$(patchfile "$pkg")" ]; then
            patch -s -p1 -d "$DEV/b/$pkg" < "$(patchfile "$pkg")" || die "$(var PATCH "$pkg") does not apply to $pkg $ver"
        fi
        echo "$pkg $ver: edit $DEV/b/$pkg"
        rm -rf "${DEV:?}/tmp"
    done
}

refresh() {
    for pkg in $PKGS; do
        [ -d "$DEV/b/$pkg" ] || { echo "$pkg: not set up, skipped (tools/patch-dev.sh setup $pkg)"; continue; }
        out=$(patchfile "$pkg")
        mkdir -p "$(dirname "$out")"
        # diff exits 1 when there are differences; -N includes added files; strip timestamps so refreshes
        # diff cleanly in git; C's order of names, not the locale's (en_US put NotificationPopup.qml after
        # components/), so every machine writes the same file
        (cd "$DEV" && LC_ALL=C diff -ruN --exclude='*.orig' --exclude='*.rej' "a/$pkg" "b/$pkg" || true) \
            | sed -E -e "s#^(---|\+\+\+) (a|b)/$pkg/#\1 \2/#" -e 's/^(---|\+\+\+) ([^\t]+)\t.*/\1 \2/' \
                  -e "s#^diff -ruN (.*)a/$pkg/(.*) b/$pkg/(.*)#diff -ruN \1a/\2 b/\3#" > "$out"
        printf '%s: %s files changed\n' "$(basename "$out")" "$(grep -c '^+++ ' "$out")"
    done
}

# KRunner alone, from a full plasma-workspace tree (CMake needs all of it) with the edited krunner/ copied
# in. cp -a keeps timestamps, so ninja only rebuilds what changed.
build_krunner() {
    [ -d "$DEV/b/plasma-workspace/krunner" ] || die "run setup first"
    ver=$(version plasma-workspace)
    src="$DEV/build/src" bld="$DEV/build/build"
    if [ "$(cat "$DEV/build/version" 2>/dev/null)" != "$ver" ]; then
        rm -rf "${DEV:?}/build" && mkdir -p "$src"
        tar -xJf "$DISTDIR/plasma-workspace-$ver.tar.xz" -C "$src" --strip-components=1
        cp -a "$DEV/b/plasma-workspace/krunner/." "$src/krunner/"
        cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTING=OFF \
            >"$DEV/build/configure.log" 2>&1 || die "cmake failed, see $DEV/build/configure.log"
        echo "$ver" > "$DEV/build/version"
    fi
    # an edited CMakeLists.txt keeps its (older) timestamp; touch it so ninja re-runs CMake
    cmp -s "$DEV/b/plasma-workspace/krunner/CMakeLists.txt" "$src/krunner/CMakeLists.txt" || cml=1
    cp -a "$DEV/b/plasma-workspace/krunner/." "$src/krunner/"
    [ -z "${cml:-}" ] || touch "$src/krunner/CMakeLists.txt"
    ninja -C "$bld" krunner >"$DEV/build/build.log" 2>&1 || { grep -m5 -A3 error "$DEV/build/build.log" >&2; die "build failed, see $DEV/build/build.log"; }
    # milou's installed qmldir prefers its compiled-in QML; a copy without that line loads the edited files
    qml="$DEV/qml/org/kde/milou"
    rm -rf "${qml:?}" && mkdir -p "$qml" && cp -r "$(qtpaths6 --query QT_INSTALL_QML 2>/dev/null || echo /usr/lib64/qt6/qml)/org/kde/milou/." "$qml/"
    sed -i '/^prefer /d' "$qml/qmldir" && cp "$DEV/b/milou/lib/"*.qml "$qml/"
    echo "$bld/bin/krunner"
}

# plasmashell alone, in KRunner's build tree (build_krunner sets it up) with the edited shell/ copied in
build_plasmashell() {
    [ -d "$DEV/b/plasma-workspace/shell" ] || die "run setup plasma-workspace first"
    build_krunner >/dev/null
    src="$DEV/build/src" bld="$DEV/build/build"
    cp -a "$DEV/b/plasma-workspace/shell/." "$src/shell/"
    ninja -C "$bld" plasmashell >"$DEV/build/build.log" 2>&1 || { grep -m5 -A3 error "$DEV/build/build.log" >&2; die "build failed, see $DEV/build/build.log"; }
    echo "$bld/bin/plasmashell"
}

# The edited KWin files compiled in the release's tree with Gentoo's patchset (the ebuild's PATCHSET), its
# CMakeLists edits and the other user patches Portage applies with ours (kde-fixes'), configured from the
# installed kwin's USE flags. Only files that differ from the release are copied in, so the rest keep
# those patches; files no longer edited go back to them.
build_kwin() {
    [ -d "$DEV/b/kwin" ] || die "run setup kwin first"
    ver=$(version kwin) k="$DEV/kwin"
    src="$k/src" bld="$k/build"
    if [ "$(cat "$k/version" 2>/dev/null)" != "$ver" ]; then
        rm -rf "${k:?}" && mkdir -p "$src"
        tar -xJf "$DISTDIR/kwin-$ver.tar.xz" -C "$src" --strip-components=1
        ebuild=$(ls /var/db/pkg/kde-plasma/kwin-"$ver"*/kwin-*.ebuild)
        ps=$(sed -n 's/^PATCHSET="\${P}\(.*\)"$/kwin-'"$ver"'\1/p' "$ebuild")
        if [ -n "$ps" ]; then
            tar -xJf "$DISTDIR/$ps.tar.xz" -C "$k" || die "$ps.tar.xz missing (emerge --fetchonly kde-plasma/kwin)"
            for p in "$k/$ps"/*.patch; do patch -s -p1 -d "$src" < "$p" || die "Gentoo's $(basename "$p") does not apply"; done
        fi
        for p in /etc/portage/patches/kde-plasma/kwin/*.patch; do
            case "$(basename "$p")" in "$PATCH_kwin"|kwin-fixes.patch) continue ;; esac  # ours, and its old name
            [ -f "$p" ] || continue
            patch -s -p1 -d "$src" < "$p" || die "$p does not apply"
        done
        use=" $(cat /var/db/pkg/kde-plasma/kwin-"$ver"*/USE) "
        for x in gamepad:libevdev screencast:PipeWire systemd:libsystemd; do  # the ebuild's src_prepare
            case "$use" in *" ${x%%:*} "*) ;; *) sed -i "s/^pkg_check_modules.*${x#*:}/#&/" "$src/CMakeLists.txt" ;; esac
        done
        on() { case "$use" in *" $1 "*) echo ON ;; *) echo OFF ;; esac; }
        cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTING=OFF \
            -DKWIN_BUILD_SCREENLOCKER="$(on lock)" -DKWIN_BUILD_GLOBALSHORTCUTS="$(on shortcuts)" \
            -DKWIN_BUILD_X11="$(on X)" -DCMAKE_DISABLE_FIND_PACKAGE_QAccessibilityClient6="$(case $(on accessibility) in ON) echo OFF ;; *) echo ON ;; esac)" \
            >"$k/configure.log" 2>&1 || die "cmake failed, see $k/configure.log"
        cp -a "$src" "$k/base"
        echo "$ver" > "$k/version"
    fi
    edited=$(cd "$DEV/b/kwin" && find . -type f | while read -r f; do cmp -s "$f" "$DEV/a/kwin/$f" || echo "${f#./}"; done)
    for f in $(cat "$k/edited" 2>/dev/null); do  # no longer edited: back as released (or gone, if the patch added it)
        echo "$edited" | grep -qx "$f" && continue
        if [ -e "$k/base/$f" ]; then cp "$k/base/$f" "$src/$f"; else rm -f "$src/$f"; fi
    done
    for f in $edited; do cmp -s "$DEV/b/kwin/$f" "$src/$f" || cp "$DEV/b/kwin/$f" "$src/$f"; done
    echo "$edited" > "$k/edited"
    # the objects built from each edited .cpp (FILE^ would pick ECM's clang-format target)
    objs=$(for f in $edited; do
        case "$f" in *.cpp) ninja -C "$bld" -t query "$src/$f" | sed -n 's/^ *\(.*\.o\)$/\1/p' ;; esac
    done)
    [ -n "$objs" ] || die "no edited .cpp files"
    # shellcheck disable=SC2086
    ninja -C "$bld" $objs >"$k/build.log" 2>&1 || { grep -m5 -A3 error "$k/build.log" >&2; die "build failed, see $k/build.log"; }
    echo "compiled: $edited" | tr '\n' ' '; echo
}

# The Shortcuts page (kcm_keys) alone, in a full plasma-desktop tree (CMake needs all of it) with the
# edited kcms/keys copied in, configured without the X11 mouse and touchpad pages (Gentoo builds those
# against headers of its own) and the tablet page (libwacom). Qt finds plugins in QT_PLUGIN_PATH before
# the installed ones, so systemsettings run with it set to the printed folder loads this build of the page.
build_keys() {
    [ -d "$DEV/b/plasma-desktop/kcms/keys" ] || die "run setup plasma-desktop first"
    ver=$(version plasma-desktop) d="$DEV/plasma-desktop"
    src="$d/src" bld="$d/build"
    if [ "$(cat "$d/version" 2>/dev/null)" != "$ver" ]; then
        rm -rf "${d:?}" && mkdir -p "$src"
        tar -xJf "$DISTDIR/plasma-desktop-$ver.tar.xz" -C "$src" --strip-components=1
        cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTING=OFF \
            -DBUILD_KCM_MOUSE_X11=OFF -DBUILD_KCM_TOUCHPAD_X11=OFF -DBUILD_KCM_TABLET=OFF -DCMAKE_DISABLE_FIND_PACKAGE_PackageKitQt6=ON \
            >"$d/configure.log" 2>&1 || die "cmake failed, see $d/configure.log"
        echo "$ver" > "$d/version"
    fi
    cp -a "$DEV/b/plasma-desktop/kcms/keys/." "$src/kcms/keys/"
    ninja -C "$bld" kcm_keys >"$d/build.log" 2>&1 || { grep -m5 -A3 error "$d/build.log" >&2; die "build failed, see $d/build.log"; }
    echo "$bld/bin"
}

# Installs the patches and rebuilds the packages whose patch changed, or which weren't rebuilt after
# their patch was installed (an earlier emerge failed); named PKGs are rebuilt regardless.
install_patches() {
    [ "$(id -u)" = 0 ] || die "install needs root"
    sh "$REPO/tools/check-patches.sh" || die "checks failed; nothing installed"
    todo=""
    for pkg in ${*:-$PKGS}; do
        cat=$(var CAT "$pkg") dest="/etc/portage/patches/$(var CAT "$pkg")/$pkg"
        mkdir -p "$dest"
        # its name until 2026-10-17, when it also held the fixes now in kde-fixes
        [ "$pkg" != kwin ] || rm -f "$dest/kwin-fixes.patch"
        # plasma-desktop's until 2026-10-22, when it took the panel's change too
        [ "$pkg" != plasma-desktop ] || rm -f "$dest/plasma-desktop-shortcut-search.patch"
        cmp -s "$(patchfile "$pkg")" "$dest/$(var PATCH "$pkg")" || install -m 644 "$(patchfile "$pkg")" "$dest/"
        built=$(cat /var/db/pkg/"$cat"/"$pkg"-[0-9]*/BUILD_TIME 2>/dev/null | head -1)
        if [ $# -gt 0 ] || [ "$(stat -c %Y "$dest/$(var PATCH "$pkg")")" -gt "${built:-0}" ]; then
            todo="$todo $cat/$pkg"
        fi
    done
    [ -n "$todo" ] || { echo "Every package is built with its current patch; nothing to rebuild."; return 0; }
    # shellcheck disable=SC2086
    emerge --oneshot --verbose $todo
    echo "As your user: systemctl --user restart plasma-plasmashell.service; kquitapp6 krunner"
    case "$todo" in *kwin*) echo "The new KWin runs from the next login." ;; esac
}

case "${1:-}" in
    setup) shift; setup "$@" ;;
    refresh) refresh ;;
    check) exec sh "$REPO/tools/check-patches.sh" ;;
    krunner) build_krunner ;;
    qt) die "the Qt patches moved to kde-fixes: ~/Projects/kde-fixes/tools/patch-dev.sh qt" ;;
    kwin) build_kwin ;;
    kcm-keys) build_keys ;;
    install) shift; install_patches "$@" ;;
    plasmashell) build_plasmashell ;;
    *) sed -n '2,27p' "$0"; exit 2 ;;
esac
