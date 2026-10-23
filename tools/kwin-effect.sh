#!/bin/sh
# The Liquid Glass effect (kwin-effect/), a KWin plugin of its own, swapped into the running KWin: no relogin,
# and no app closes.
#
#   tools/kwin-effect.sh build            a build of its own (a new id each time, a folder of that name) in
#                                          ~/.cache/plasma-glass/effect; prints its liquidglass.so
#   tools/kwin-effect.sh install [LIB]    (root) LIB (default: a new build) into STORE, linked from KWin's plugin
#                                          folder as liquidglass.so (KWin's name for the effect); older builds go.
#                                          From a checkout, its source goes to SHARE too, so Portage's hook builds
#                                          the same effect after a KWin update
#   tools/kwin-effect.sh reload           (as the desktop user) KWin drops the effect it runs (Liquid Glass, or the
#                                          built-in blur the first time) and loads Liquid Glass through the link;
#                                          prints the build now running
#   tools/kwin-effect.sh enable           (as the desktop user) kwinrc: Liquid Glass in place of the built-in blur,
#                                          as KWin starts too
#   tools/kwin-effect.sh disable          (as the desktop user) the built-in blur again, now and as KWin starts
#   tools/kwin-effect.sh status           which is loaded, and which build
#
# A new version in one go, as the desktop user: tools/kwin-effect.sh build, sudo tools/kwin-effect.sh install
# LIB, tools/kwin-effect.sh reload (desktop/plasma-glass-reload-kwin does the three). The plugin only loads
# into the KWin version it was built against; after a KWin update install builds it again (Portage's hook,
# see install-system.sh).
#
# KWIN_EFFECT_PLUGINDIR and KWIN_EFFECT_STORE move the link and the builds (the preview's swap test).
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
SHARE=/usr/local/share/plasma-glass  # the source and this tool, for Portage's hook (install-system.sh, install)
SRC="$REPO/kwin-effect"
[ -d "$SRC" ] || SRC="$SHARE/kwin-effect"
BUILD="${XDG_CACHE_HOME:-$HOME/.cache}/plasma-glass/effect"
PLUGINDIR="${KWIN_EFFECT_PLUGINDIR:-$(qtpaths6 --query QT_INSTALL_PLUGINS 2>/dev/null || echo /usr/lib64/qt6/plugins)/kwin/effects/plugins}"
STORE="${KWIN_EFFECT_STORE:-/usr/local/lib64/plasma-glass/kwin-effect}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
effects() { qdbus6 org.kde.KWin /Effects "org.kde.kwin.Effects.$@"; }

build() {
    id=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BUILD"
    # Portage's flags, as KWin itself is built with
    CXXFLAGS="$(portageq envvar CXXFLAGS 2>/dev/null || echo -O2)" \
        cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DPLASMA_GLASS_BUILD_ID="$id" \
        >"$BUILD/configure.log" 2>&1 || die "cmake failed, see $BUILD/configure.log"
    ninja -C "$BUILD" >"$BUILD/build.log" 2>&1 || { grep -m5 -A3 error "$BUILD/build.log" >&2; die "build failed, see $BUILD/build.log"; }
    lib="$BUILD/$id/liquidglass.so"
    [ -f "$lib" ] || die "no $lib"
    # builds before this one go (installed copies are kept in STORE)
    find "$BUILD" -mindepth 1 -maxdepth 1 -type d -name '20*-*' ! -name "$id" -exec rm -r {} +
    echo "$lib"
}

install_lib() {
    lib="${1:-$(build)}"
    [ -f "$lib" ] || die "no library $lib"
    id=$(basename "$(dirname "$lib")")
    mkdir -p "$STORE/$id" "$PLUGINDIR"
    install -m 755 "$lib" "$STORE/$id/liquidglass.so"
    # the link KWin finds, replaced in one step
    ln -sfn "$STORE/$id/liquidglass.so" "$PLUGINDIR/liquidglass.so.new" && mv -T "$PLUGINDIR/liquidglass.so.new" "$PLUGINDIR/liquidglass.so"
    # older builds: a KWin that loaded one keeps it mapped, deleted
    find "$STORE" -mindepth 1 -maxdepth 1 -type d ! -name "$id" -exec rm -r {} +
    echo "$PLUGINDIR/liquidglass.so -> $STORE/$id/liquidglass.so"
    # what Portage's hook builds from: this source, if it's a checkout's (not the preview's scratch store)
    if [ "$SRC" != "$SHARE/kwin-effect" ] && [ -z "${KWIN_EFFECT_STORE:-}" ]; then
        rm -rf "${SHARE:?}/kwin-effect" && mkdir -p "$SHARE/tools" && cp -r "$SRC" "$SHARE/" && install -m 755 "$REPO/tools/kwin-effect.sh" "$SHARE/tools/"
    fi
}

running_build() {
    # (the built-in blur of a KWin from before 2026-10-22 has the object, but no Build)
    out=$(qdbus6 org.kde.KWin /org/kde/KWin/LiquidGlass org.kde.KWin.LiquidGlass.Build 2>/dev/null) || out=
    case "$out" in 20*) echo "$out" ;; esac
}

reload() {
    [ -e "$PLUGINDIR/liquidglass.so" ] || die "no $PLUGINDIR/liquidglass.so (install first)"
    want=$(basename "$(dirname "$(readlink -f "$PLUGINDIR/liquidglass.so")")")
    [ "$(effects isEffectLoaded liquidglass)" = true ] && effects unloadEffect liquidglass
    [ "$(effects isEffectLoaded blur)" = true ] && effects unloadEffect blur
    [ "$(effects loadEffect liquidglass)" = true ] || die "KWin didn't load liquidglass (built for another KWin? see journalctl --user -u plasma-kwin_wayland)"
    now=$(running_build)
    [ "$now" = "$want" ] || die "KWin runs build ${now:-none}, not $want"
    echo "KWin runs Liquid Glass $now"
}

enable() {
    kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled false
    kwriteconfig6 --file kwinrc --group Plugins --key liquidglassEnabled true
    echo "kwinrc: Liquid Glass in place of Blur"
}

disable() {
    kwriteconfig6 --file kwinrc --group Plugins --key liquidglassEnabled false
    kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled --delete
    [ "$(effects isEffectLoaded liquidglass)" = true ] && effects unloadEffect liquidglass
    effects loadEffect blur >/dev/null
    echo "the built-in blur again"
}

status() {
    printf 'liquidglass: %s (build %s)\nblur: %s\nlink: %s\n' "$(effects isEffectLoaded liquidglass)" "$(running_build)" \
        "$(effects isEffectLoaded blur)" "$(readlink -f "$PLUGINDIR/liquidglass.so" 2>/dev/null || echo none)"
}

case "${1:-}" in
    build) build ;;
    install) shift; install_lib "$@" ;;
    reload) reload ;;
    enable) enable ;;
    disable) disable ;;
    status) status ;;
    *) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
