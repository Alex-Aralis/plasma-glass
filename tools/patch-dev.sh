#!/bin/sh
# Work on the Plasma patches as plain files instead of hand-editing diffs.
#
#   tools/patch-dev.sh setup     pristine + patched copies of the touched source dirs, for the installed
#                                versions, in ~/.cache/plasma-glass/dev/{a,b}/<package>
#   (edit files under ~/.cache/plasma-glass/dev/b/<package>/...)
#   tools/patch-dev.sh refresh   regenerate patches/kde-plasma/*/*.patch from the edits
#   tools/patch-dev.sh check     tools/check-patches.sh (patches apply, QML loads, C++ compiles)
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
        # diff exits 1 when there are differences; strip timestamps so refreshes diff cleanly in git
        (cd "$DEV" && diff -ru --exclude='*.orig' --exclude='*.rej' "a/$pkg" "b/$pkg" || true) \
            | sed -E -e "s#^(---|\+\+\+) (a|b)/$pkg/#\1 \2/#" -e 's/^(---|\+\+\+) ([^\t]+)\t.*/\1 \2/' \
                  -e "s#^diff -ru (.*)a/$pkg/(.*) b/$pkg/(.*)#diff -ru \1a/\2 b/\3#" > "$out"
        printf '%s: %s files changed\n' "$(basename "$out")" "$(grep -c '^+++ ' "$out")"
    done
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
    install) install_patches ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
esac
