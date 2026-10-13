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
#   tools/patch-dev.sh qt        build Qt's Wayland client (libQt6WaylandClient, the wayland platform plugin
#                                and its EGL plugin) from the edited qtbase tree, configured like the
#                                installed qtbase (about 2 min the first time, then seconds), and print the
#                                environment that runs an app on it, e.g.
#                                    KRUNNER_ENV="$(tools/patch-dev.sh qt)" tools/preview/unfold.sh
#   tools/patch-dev.sh install [PKG...]  (root) put the patches in /etc/portage/patches and rebuild the
#                                packages whose patch changed or that weren't rebuilt since (or the PKGs named)
#
# Packages: plasma-workspace, milou (kde-plasma) and qtbase (dev-qt). Each has a single patch file; setup
# extracts whole directories (DIRS below), so any file in them can be edited and refresh picks it up. To
# touch another directory, add it to DIRS and re-run setup.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
DEV="${XDG_CACHE_HOME:-$HOME/.cache}/plasma-glass/dev"
DISTDIR=$(portageq envvar DISTDIR 2>/dev/null || echo /var/cache/distfiles)
PKGS="plasma-workspace milou qtbase"
CAT_plasma_workspace=kde-plasma CAT_milou=kde-plasma CAT_qtbase=dev-qt
DIRS_plasma_workspace="krunner applets/notifications"
DIRS_milou="lib"
DIRS_qtbase="src/plugins/platforms/wayland"
PATCH_plasma_workspace=plasma-workspace-tweaks.patch
PATCH_milou=milou-section-headers.patch
PATCH_qtbase=qtbase-wayland.patch

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
var() { eval "echo \"\$${1}_$(echo "$2" | tr - _)\""; }

# installed version of PKG without the revision, e.g. 6.11.2
version() {
    cat=$(var CAT "$1")
    portageq best_version / "$cat/$1" 2>/dev/null | sed -E "s|^$cat/$1-||; s|-r[0-9]+$||"
}
srcdir() { case "$1" in qtbase) echo "qtbase-everywhere-src-$2" ;; *) echo "$1-$2" ;; esac; }  # tarball's top dir
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
        # diff cleanly in git
        (cd "$DEV" && diff -ruN --exclude='*.orig' --exclude='*.rej' "a/$pkg" "b/$pkg" || true) \
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

# Qt's Wayland client alone, from a full qtbase tree with Gentoo's patches and the edited wayland dir
# copied in, configured from the installed qtbase's USE flags the way its ebuild does. The libraries
# only stand in for the installed ones if every feature matches, so the generated feature headers are
# compared with the installed ones after each build.
build_qt() {
    [ -d "$DEV/b/qtbase" ] || die "run setup qtbase first"
    command -v patchelf >/dev/null || die "needs patchelf (dev-util/patchelf)"
    ver=$(version qtbase) q="$DEV/qt"
    src="$q/src" bld="$q/build" run="$q/run"
    if [ "$(cat "$q/version" 2>/dev/null)" != "$ver" ]; then
        rm -rf "${q:?}" && mkdir -p "$src"
        tar -xJf "$DISTDIR/$(srcdir qtbase "$ver").tar.xz" -C "$src" --strip-components=1
        files="$(portageq get_repo_path / gentoo)/dev-qt/qtbase/files"
        for p in $(sed -n '/^PATCHES=(/,/^)/p' /var/db/pkg/dev-qt/qtbase-"$ver"*/qtbase-*.ebuild \
                   | sed -n 's|.*"\${FILESDIR}"/\${PN}\(-.*\.patch\).*|\1|p'); do
            patch -s -p1 -d "$src" < "$files/qtbase$p" || die "Gentoo's qtbase$p does not apply"
        done
        cp -a "$DEV/b/qtbase/." "$src/"
        use=" $(cat /var/db/pkg/dev-qt/qtbase-"$ver"*/USE) "
        f() { flag=$1; shift; for feat; do case "$use" in *" $flag "*) echo "-DQT_FEATURE_$feat=ON" ;; *) echo "-DQT_FEATURE_$feat=OFF" ;; esac; done; }
        gl=no; case "$use" in *" opengl "*) case "$use" in *" gles2-only "*) gl=es2 ;; *) gl=desktop ;; esac ;; esac
        # shellcheck disable=SC2046
        cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DINSTALL_LIBDIR=lib64 \
            -DINSTALL_PLUGINSDIR=lib64/qt6/plugins -DBUILD_WITH_PCH=OFF -DQT_UNITY_BUILD=ON \
            -DQT_FEATURE_force_system_libs=ON -DQT_FEATURE_relocatable=OFF -DQT_FEATURE_jemalloc=OFF \
            -DQT_FEATURE_androiddeployqt=OFF -DQT_FEATURE_testlib=ON -DQT_FEATURE_glibc_fortify_source=OFF \
            -DQT_FEATURE_intelcet=OFF -DQT_FEATURE_libcpp_hardening=OFF -DQT_FEATURE_libstdcpp_assertions=OFF \
            -DQT_FEATURE_relro_now_linker=OFF -DQT_FEATURE_stack_clash_protection=OFF -DQT_FEATURE_stack_protector=OFF \
            -DQT_FEATURE_trivial_auto_var_init_pattern=OFF -DQT_INTERNAL_AVOID_OVERRIDING_SYNCQT_CONFIG=ON \
            -DQT_FEATURE_sql_db2=OFF -DQT_FEATURE_sql_ibase=OFF -DQT_FEATURE_sql_mimer=OFF -DINPUT_opengl=$gl \
            $(f ssl openssl openssl_linked) $(f udev libudev) $(f zstd zstd) $(f icu icu) $(f io-uring liburing) \
            $(f journald journald) $(f syslog syslog) $(f concurrent concurrent) $(f dbus dbus) $(f gui gui) \
            $(f network network) $(f sql sql) $(f xml xml) $(f X xcb system_xcb_xinput xkbcommon_x11) \
            $(f accessibility accessibility_atspi_bridge) $(f eglfs eglfs) $(f evdev evdev mtdev) \
            $(f libinput libinput) $(f renderdoc graphicsframecapture) $(f tslib tslib) $(f vulkan vulkan) \
            $(f wayland wayland) $(f widgets widgets) $(f cups cups) $(f gtk gtk3) $(f brotli brotli) \
            $(f gssapi gssapi) $(f libproxy libproxy) $(f sctp sctp) $(f mysql sql_mysql) $(f oci8 sql_oci) \
            $(f odbc sql_odbc) $(f postgres sql_psql) $(f sqlite sql_sqlite system_sqlite) \
            >"$q/configure.log" 2>&1 || die "cmake failed, see $q/configure.log"
        echo "$ver" > "$q/version"
    fi
    cp -a "$DEV/b/qtbase/." "$src/"
    ninja -C "$bld" WaylandClient QWaylandIntegrationPlugin QWaylandEglClientBufferPlugin >"$q/build.log" 2>&1 \
        || { grep -m5 -A3 error "$q/build.log" >&2; die "build failed, see $q/build.log"; }
    inc=$(qtpaths6 --query QT_INSTALL_HEADERS 2>/dev/null || echo /usr/include/qt6)
    for h in corelib/qtcore-config.h corelib/qtcore-config_p.h gui/qtgui-config.h gui/qtgui-config_p.h \
             plugins/platforms/wayland/qtwaylandclient-config.h plugins/platforms/wayland/qtwaylandclient-config_p.h; do
        grep '#define' "$(find "$inc" -name "${h##*/}" | head -1)" | sort > "$q/installed.h"
        grep '#define' "$bld/src/$h" | sort > "$q/built.h"
        cmp -s "$q/installed.h" "$q/built.h" || { diff "$q/installed.h" "$q/built.h" >&2; die "${h##*/} differs from the installed Qt's"; }
    done
    rm -rf "${run:?}" && mkdir -p "$run/lib" "$run/plugins/platforms" "$run/plugins/wayland-graphics-integration-client"
    cp "$bld/lib64/libQt6WaylandClient.so.$ver" "$run/lib/libQt6WaylandClient.so.6"
    cp "$bld/lib64/qt6/plugins/platforms/libqwayland.so" "$run/plugins/platforms/"
    cp "$bld/lib64/qt6/plugins/wayland-graphics-integration-client/libqt-plugin-wayland-egl.so" \
        "$run/plugins/wayland-graphics-integration-client/"
    # the build tree's runpath would load its own QtCore and QtGui next to the installed ones
    for lib in "$run"/lib/* "$run"/plugins/*/*; do patchelf --remove-rpath "$lib"; done
    echo "LD_LIBRARY_PATH=$run/lib QT_QPA_PLATFORM_PLUGIN_PATH=$run/plugins/platforms QT_PLUGIN_PATH=$run/plugins"
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
    case "$todo" in *qtbase*) echo "Running Qt apps keep the old Qt until they restart (log out and in to restart them all)." ;; esac
}

case "${1:-}" in
    setup) shift; setup "$@" ;;
    refresh) refresh ;;
    check) exec sh "$REPO/tools/check-patches.sh" ;;
    krunner) build_krunner ;;
    qt) build_qt ;;
    install) shift; install_patches "$@" ;;
    *) sed -n '2,23p' "$0"; exit 2 ;;
esac
