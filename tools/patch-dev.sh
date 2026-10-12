#!/bin/sh
# Work on the Plasma patches as plain files instead of hand-editing diffs.
#
#   tools/patch-dev.sh setup     pristine + patched copies of the touched source dirs, for the installed
#                                versions, in ~/.cache/plasma-glass/dev/{a,b}/<package>
#   (edit files under ~/.cache/plasma-glass/dev/b/<package>/...)
#   tools/patch-dev.sh refresh   regenerate patches/kde-plasma/*/*.patch from the edits
#   tools/patch-dev.sh check     tools/check-patches.sh (patches apply, QML loads, C++ compiles)
#   tools/patch-dev.sh krunner   build just KRunner from the edited tree (about 10 s once configured) and
#                                print its path; also puts the edited milou QML in ~/.cache/plasma-glass/dev/qml.
#                                Preview with: QML_IMPORT_PATH=~/.cache/plasma-glass/dev/qml \
#                                    KRUNNER=$(tools/patch-dev.sh krunner) tools/preview/krunner.sh OUT.png
#   tools/patch-dev.sh install   (root) put the patches in /etc/portage/patches and rebuild both packages
#
# Each package has a single patch file; setup extracts whole directories (krunner, applets/notifications,
# lib), so any file in them can be edited and refresh picks it up. To touch another directory, add it to
# DIRS below and re-run setup.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
DEV="${XDG_CACHE_HOME:-$HOME/.cache}/plasma-glass/dev"
DISTDIR=$(portageq envvar DISTDIR 2>/dev/null || echo /var/cache/distfiles)
DIRS_plasma_workspace="krunner applets/notifications"
DIRS_milou="lib"
PATCH_plasma_workspace=plasma-workspace-tweaks.patch
PATCH_milou=milou-section-headers.patch

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
var() { eval "echo \"\$${1}_$(echo "$2" | tr - _)\""; }

version() {
    portageq best_version / "kde-plasma/$1" 2>/dev/null | sed -E "s|^kde-plasma/$1-||; s|-r[0-9]+$||"
}

setup() {
    for pkg in plasma-workspace milou; do
        ver=$(version "$pkg"); [ -n "$ver" ] || die "kde-plasma/$pkg is not installed"
        tarball="$DISTDIR/$pkg-$ver.tar.xz"
        [ -f "$tarball" ] || die "$tarball missing (emerge --fetchonly kde-plasma/$pkg)"
        if [ -d "$DEV/b/$pkg" ] && [ "${FORCE:-0}" != 1 ]; then
            die "$DEV/b/$pkg exists (FORCE=1 to discard it and start over)"
        fi
        rm -rf "$DEV/a/$pkg" "$DEV/b/$pkg" "$DEV/tmp"
        mkdir -p "$DEV/a/$pkg" "$DEV/b" "$DEV/tmp"
        # shellcheck disable=SC2046
        tar -xJf "$tarball" -C "$DEV/tmp" $(for d in $(var DIRS "$pkg"); do echo "$pkg-$ver/$d"; done)
        cp -r "$DEV/tmp/$pkg-$ver/." "$DEV/a/$pkg/"
        cp -r "$DEV/a/$pkg" "$DEV/b/$pkg"
        patch -s -p1 -d "$DEV/b/$pkg" < "$REPO/patches/kde-plasma/$pkg/$(var PATCH "$pkg")" \
            || die "$(var PATCH "$pkg") does not apply to $pkg $ver"
        echo "$pkg $ver: edit $DEV/b/$pkg"
        rm -rf "$DEV/tmp"
    done
}

refresh() {
    for pkg in plasma-workspace milou; do
        [ -d "$DEV/b/$pkg" ] || die "run setup first"
        out="$REPO/patches/kde-plasma/$pkg/$(var PATCH "$pkg")"
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
        rm -rf "$DEV/build" && mkdir -p "$src"
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
    rm -rf "$qml" && mkdir -p "$qml" && cp -r "$(qtpaths6 --query QT_INSTALL_QML 2>/dev/null || echo /usr/lib64/qt6/qml)/org/kde/milou/." "$qml/"
    sed -i '/^prefer /d' "$qml/qmldir" && cp "$DEV/b/milou/lib/"*.qml "$qml/"
    echo "$bld/bin/krunner"
}

install_patches() {
    [ "$(id -u)" = 0 ] || die "install needs root"
    sh "$REPO/tools/check-patches.sh" || die "checks failed; nothing installed"
    for pkg in plasma-workspace milou; do
        mkdir -p "/etc/portage/patches/kde-plasma/$pkg"
        install -m 644 "$REPO/patches/kde-plasma/$pkg/$(var PATCH "$pkg")" "/etc/portage/patches/kde-plasma/$pkg/"
    done
    emerge --oneshot --verbose kde-plasma/milou kde-plasma/plasma-workspace
    echo "As your user: systemctl --user restart plasma-plasmashell.service; kquitapp6 krunner"
}

case "${1:-}" in
    setup) setup ;;
    refresh) refresh ;;
    check) exec sh "$REPO/tools/check-patches.sh" ;;
    krunner) build_krunner ;;
    install) install_patches ;;
    *) sed -n '2,19p' "$0"; exit 2 ;;
esac
