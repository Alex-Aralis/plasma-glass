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
#   tools/patch-dev.sh qt        build the patched Qt libraries from the edited trees that are set up, each
#                                configured like its installed package: from qtbase, Qt's Wayland client
#                                (libQt6WaylandClient, the wayland platform plugin and its EGL plugin); from
#                                qtdeclarative, libQt6Quick. A few minutes the first time, then seconds.
#                                Prints the environment that runs an app on them instead of the installed ones:
#                                    KRUNNER_ENV="$(tools/patch-dev.sh qt)" tools/preview/unfold.sh
#   tools/patch-dev.sh kwin      compile the edited KWin files in a KWin tree configured like its ebuild, with
#                                Gentoo's patchset, to check them before the emerge (a few minutes the first
#                                time, then seconds). The patched KWin only runs after the emerge and a relogin.
#   tools/patch-dev.sh install [PKG...]  (root) put the patches in /etc/portage/patches and rebuild the
#                                packages whose patch changed or that weren't rebuilt since (or the PKGs named)
#
# Packages: plasma-workspace, milou, kwin (kde-plasma), qtbase and qtdeclarative (dev-qt). Each has a single patch file; setup
# extracts whole directories (DIRS below), so any file in them can be edited and refresh picks it up. To
# touch another directory, add it to DIRS and re-run setup.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
DEV="${XDG_CACHE_HOME:-$HOME/.cache}/plasma-glass/dev"
DISTDIR=$(portageq envvar DISTDIR 2>/dev/null || echo /var/cache/distfiles)
PKGS="plasma-workspace milou kwin qtbase qtdeclarative"
CAT_plasma_workspace=kde-plasma CAT_milou=kde-plasma CAT_kwin=kde-plasma CAT_qtbase=dev-qt CAT_qtdeclarative=dev-qt
DIRS_plasma_workspace="krunner applets/notifications"
DIRS_milou="lib"
DIRS_kwin="src"
DIRS_qtbase="src/plugins/platforms/wayland"
DIRS_qtdeclarative="src/quick/scenegraph"
PATCH_plasma_workspace=plasma-workspace-tweaks.patch
PATCH_milou=milou-section-headers.patch
PATCH_kwin=kwin-fixes.patch
PATCH_qtbase=qtbase-wayland.patch
PATCH_qtdeclarative=qtdeclarative-quick.patch
RUN="$DEV/qt-run"  # the libraries `qt` builds, where its environment points

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
var() { eval "echo \"\$${1}_$(echo "$2" | tr - _)\""; }

# installed version of PKG without the revision, e.g. 6.11.2
version() {
    cat=$(var CAT "$1")
    portageq best_version / "$cat/$1" 2>/dev/null | sed -E "s|^$cat/$1-||; s|-r[0-9]+$||"
}
srcdir() { case "$(var CAT "$1")" in dev-qt) echo "$1-everywhere-src-$2" ;; *) echo "$1-$2" ;; esac; }  # tarball's top dir
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

# The Qt builds below stand in for installed libraries, which only works if every feature matches, so
# each build's generated feature headers are compared with the installed ones.
use_of() { echo " $(cat /var/db/pkg/dev-qt/"$1"-"$(version "$1")"*/USE) "; }
f() { flag=$1; shift; for feat; do case "$use" in *" $flag "*) echo "-DQT_FEATURE_$feat=ON" ;; *) echo "-DQT_FEATURE_$feat=OFF" ;; esac; done; }
check_features() {  # check_features BUILD_DIR HEADER... (paths under BUILD_DIR/src)
    inc=$(qtpaths6 --query QT_INSTALL_HEADERS 2>/dev/null || echo /usr/include/qt6) b=$1
    shift
    for h; do
        grep '#define' "$(find "$inc" -name "${h##*/}" | head -1)" | sort > "$b/installed.h"
        grep '#define' "$b/src/$h" | sort > "$b/built.h"
        cmp -s "$b/installed.h" "$b/built.h" || { diff "$b/installed.h" "$b/built.h" >&2; die "${h##*/} differs from the installed Qt's"; }
    done
}
stage() {  # stage FILE DIR [NAME]: copy into the run dir, without the build tree's runpath (it would load
           # the build's own QtCore and QtGui next to the installed ones)
    mkdir -p "$RUN/$2" && cp "$1" "$RUN/$2/${3:-$(basename "$1")}" && patchelf --remove-rpath "$RUN/$2/${3:-$(basename "$1")}"
}
# fresh_tree PKG DIR: the package's source with Gentoo's own patches (the ebuild's PATCHES) and the edited dirs
fresh_tree() {
    rm -rf "${2:?}" && mkdir -p "$2/src"
    tar -xJf "$DISTDIR/$(srcdir "$1" "$ver").tar.xz" -C "$2/src" --strip-components=1
    files="$(portageq get_repo_path / gentoo)/dev-qt/$1/files"
    for p in $(sed -n '/^PATCHES=(/,/^)/p' /var/db/pkg/dev-qt/"$1"-"$ver"*/"$1"-*.ebuild \
               | sed -n 's|.*"\${FILESDIR}"/\${PN}\(-.*\.patch\).*|\1|p'); do
        patch -s -p1 -d "$2/src" < "$files/$1$p" || die "Gentoo's $1$p does not apply"
    done
    cp -a "$DEV/b/$1/." "$2/src/"
}

# Qt's Wayland client alone, from a full qtbase tree, configured from the installed qtbase's USE flags
# the way its ebuild does.
build_qtbase() {
    ver=$(version qtbase) q="$DEV/qt"
    src="$q/src" bld="$q/build"
    if [ "$(cat "$q/version" 2>/dev/null)" != "$ver" ]; then
        fresh_tree qtbase "$q"
        use=$(use_of qtbase)
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
    check_features "$bld" corelib/qtcore-config.h corelib/qtcore-config_p.h gui/qtgui-config.h gui/qtgui-config_p.h \
        plugins/platforms/wayland/qtwaylandclient-config.h plugins/platforms/wayland/qtwaylandclient-config_p.h
    stage "$bld/lib64/libQt6WaylandClient.so.$ver" lib libQt6WaylandClient.so.6
    stage "$bld/lib64/qt6/plugins/platforms/libqwayland.so" plugins/platforms
    stage "$bld/lib64/qt6/plugins/wayland-graphics-integration-client/libqt-plugin-wayland-egl.so" \
        plugins/wayland-graphics-integration-client
    echo "QT_QPA_PLATFORM_PLUGIN_PATH=$RUN/plugins/platforms QT_PLUGIN_PATH=$RUN/plugins" > "$RUN/qtbase.env"
}

# libQt6Quick alone, from qtdeclarative built as a module against the installed qtbase, like its ebuild
build_qtdeclarative() {
    ver=$(version qtdeclarative) q="$DEV/qtdeclarative"
    src="$q/src" bld="$q/build"
    if [ "$(cat "$q/version" 2>/dev/null)" != "$ver" ]; then
        fresh_tree qtdeclarative "$q"
        use=$(use_of qtdeclarative)
        qmlls=ON; case "$use" in *" qmlls "*) qmlls=OFF ;; esac
        # shellcheck disable=SC2046
        cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_WITH_PCH=OFF -DQT_UNITY_BUILD=ON \
            -DCMAKE_DISABLE_FIND_PACKAGE_Qt6LanguageServerPrivate=$qmlls \
            $(f jit qml_jit) $(f network qml_network) $(f ssl qml_ssl) \
            >"$q/configure.log" 2>&1 || die "cmake failed, see $q/configure.log"
        echo "$ver" > "$q/version"
    fi
    cp -a "$DEV/b/qtdeclarative/." "$src/"
    ninja -C "$bld" Quick >"$q/build.log" 2>&1 || { grep -m5 -A3 error "$q/build.log" >&2; die "build failed, see $q/build.log"; }
    check_features "$bld" quick/qtquick-config.h quick/qtquick-config_p.h qml/qtqml-config.h qml/qtqml-config_p.h
    stage "$bld/lib64/libQt6Quick.so.$ver" lib libQt6Quick.so.6
}

build_qt() {
    command -v patchelf >/dev/null || die "needs patchelf (dev-util/patchelf)"
    rm -rf "${RUN:?}" && mkdir -p "$RUN/lib"
    built=""
    for pkg in qtbase qtdeclarative; do
        [ -d "$DEV/b/$pkg" ] || continue
        "build_$pkg" && built="$built $pkg"
    done
    [ -n "$built" ] || die "nothing to build: tools/patch-dev.sh setup qtbase (or qtdeclarative) first"
    echo "LD_LIBRARY_PATH=$RUN/lib $(cat "$RUN/qtbase.env" 2>/dev/null)"
}

# The edited KWin files compiled in the release's tree with Gentoo's patchset (the ebuild's PATCHSET) and
# its CMakeLists edits, configured from the installed kwin's USE flags. Only files that differ from the
# release are copied in, so the rest keep Gentoo's patches; files no longer edited go back to those.
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
    for f in $(cat "$k/edited" 2>/dev/null); do
        echo "$edited" | grep -qx "$f" || cp "$k/base/$f" "$src/$f"
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
    case "$todo" in *kwin*) echo "The new KWin runs from the next login." ;; esac
    case "$todo" in *qtbase*) echo "Running Qt apps keep the old Qt until they restart (log out and in to restart them all)." ;; esac
}

case "${1:-}" in
    setup) shift; setup "$@" ;;
    refresh) refresh ;;
    check) exec sh "$REPO/tools/check-patches.sh" ;;
    krunner) build_krunner ;;
    qt) build_qt ;;
    kwin) build_kwin ;;
    install) shift; install_patches "$@" ;;
    *) sed -n '2,27p' "$0"; exit 2 ;;
esac
