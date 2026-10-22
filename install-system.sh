#!/bin/sh
# plasma-glass installer, system part (Gentoo). Run as root from the repo:
#
#   sudo ./install-system.sh                   GPU compute runtime + Portage patches + rebuild
#   sudo ./install-system.sh --help            options
#
# 1. Intel GPU compute runtime (OpenCL/Level Zero) so OpenVINO can run the search model on the iGPU.
# 2. Portage user patches for kde-plasma/plasma-workspace (KRunner + notification popups, the panel's
#    shadow), kde-plasma/milou (KRunner result rows), kde-plasma/kwin (Window Behavior opening on a tab)
#    and kde-plasma/plasma-desktop (the Shortcuts page opening on an action, the panel's popups), then
#    rebuilds the packages whose patch is new or changed. Portage re-applies the patches on every future
#    update of those packages.
# 3. The Liquid Glass effect (kwin-effect/: the styles' glass and the liquid), a KWin plugin of its own in place
#    of the built-in blur: built, put in KWin's plugin folder, and built again by Portage after every KWin
#    update (/etc/portage/env/kde-plasma/kwin). It swaps into a running KWin with tools/kwin-effect.sh reload.
#
# The fixes for bugs in KDE and Qt that plasma-glass carried until 2026-10-17 (KWin's frame pacing, its
# crash at logout and activation tokens, KSvg's colours after a style switch, Qt's resize glitches and
# 60 fps animations) are in their own repo, kde-fixes: install it too (its install.sh).
set -eu

REPO=$(cd "$(dirname "$0")" && pwd)
RUNTIME=auto REBUILD=1 CHECKS=1
for arg in "$@"; do
    case "$arg" in
        --runtime=*) RUNTIME=${arg#--runtime=} ;;
        --no-rebuild) REBUILD=0 ;;
        --skip-checks) CHECKS=0 ;;
        -h|--help)
            cat <<EOF
usage: sudo ./install-system.sh [options]
  --runtime=auto|legacy|current|skip
        Intel compute runtime to install. auto (default) picks from the iGPU:
        legacy  dev-libs/intel-compute-runtime:legacy  (up to 12th-14th gen Iris Xe / UHD; tested on Alder Lake)
        current dev-libs/intel-compute-runtime         (Meteor Lake / Core Ultra, Arc and newer)
  --no-rebuild
        install the Portage patches but don't rebuild the patched packages now
  --skip-checks
        don't run tools/check-patches.sh (patches apply, QML loads, C++ compiles) first
EOF
            exit 0 ;;
        *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root: sudo ./install-system.sh"
command -v emerge >/dev/null || die "this script is for Gentoo (Portage). On other distros apply patches/ by hand."

# --- 1. Intel compute runtime -------------------------------------------------------------------
gpu=$(lspci 2>/dev/null | grep -E 'VGA|3D|Display' | grep -i intel | head -1 || true)
if [ "$RUNTIME" = auto ]; then
    case "$gpu" in
        "") RUNTIME=skip ;;
        *Meteor*|*Arrow*|*Lunar*|*Panther*|*Battlemage*|*Alchemist*|*DG2*|*" Arc"*) RUNTIME=current ;;
        *Alder*|*Raptor*|*Tiger*|*Rocket*|*Ice*Lake*|*Comet*|*Coffee*|*Whiskey*|*Kaby*|*Skylake*|*Jasper*|*Elkhart*|*Gemini*|*UHD*|*Iris*|*"HD Graphics"*) RUNTIME=legacy ;;
        *) RUNTIME=current ;;
    esac
fi
echo "Intel GPU: ${gpu:-none found}  ->  runtime: $RUNTIME"

if [ "$RUNTIME" != skip ]; then
    if portageq has_version / dev-libs/intel-compute-runtime 2>/dev/null; then
        say "Intel compute runtime already installed: $(portageq best_version / dev-libs/intel-compute-runtime)"
    else
        case "$RUNTIME" in
            legacy) atom="dev-libs/intel-compute-runtime:legacy" ;;
            current) atom="dev-libs/intel-compute-runtime" ;;
            *) die "unknown --runtime=$RUNTIME" ;;
        esac
        # the legacy runtime and its binary compiler are only keyworded ~amd64
        if [ "$RUNTIME" = legacy ] && ! portageq envvar ACCEPT_KEYWORDS | grep -q '~amd64'; then
            say "Accepting ~amd64 for the legacy runtime and its compiler"
            kw=/etc/portage/package.accept_keywords
            [ -e "$kw" ] || mkdir -p "$kw"
            [ -d "$kw" ] && kw="$kw/plasma-glass"
            for a in "dev-libs/intel-compute-runtime:legacy ~amd64" "dev-util/intel-graphics-compiler-bin ~amd64"; do
                grep -qxF "$a" "$kw" 2>/dev/null || echo "$a" >> "$kw"
            done
        fi
        say "Installing $atom"
        emerge --noreplace --verbose "$atom" virtual/opencl dev-libs/opencl-icd-loader
    fi
fi

# --- 2. Portage user patches ---------------------------------------------------------------------
if [ "$CHECKS" = 1 ]; then
    say "Checking the patches against your installed Plasma (about 10 s)"
    sh "$REPO/tools/check-patches.sh" || die "patch checks failed; nothing was installed (override with --skip-checks)"
fi
say "Installing Portage user patches"
pkgs="kde-plasma/plasma-workspace kde-plasma/milou kde-plasma/kwin kde-plasma/plasma-desktop"
rebuild=""
for atom in $pkgs; do
    dest=/etc/portage/patches/$atom
    mkdir -p "$dest"
    # names used by earlier versions of these patches (kwin-fixes.patch until 2026-10-17, with the fixes
    # that are kde-fixes' now; plasma-desktop-shortcut-search.patch and kwin-liquid-glass.patch, whose glass is a
    # plugin of its own now, until 2026-10-22)
    rm -f "$dest/krunner-hide-pin.patch" "$dest/krunner-tweaks.patch" "$dest/kwin-fixes.patch" \
        "$dest/plasma-desktop-shortcut-search.patch" "$dest/kwin-liquid-glass.patch"
    for p in "$REPO"/patches/$atom/*.patch; do
        cmp -s "$p" "$dest/$(basename "$p")" || install -m 644 "$p" "$dest/"
        # rebuild if the patch is newer than the installed build (new, changed, or an earlier emerge failed)
        built=$(cat /var/db/pkg/"$atom"-[0-9]*/BUILD_TIME 2>/dev/null | head -1)
        if [ "$(stat -c %Y "$dest/$(basename "$p")")" -gt "${built:-0}" ]; then rebuild="$rebuild $atom"; fi
    done
    echo "  $dest: $(cd "$dest" && ls | tr '\n' ' ')"
done
for atom in $pkgs; do
    want=6.7.5
    have=$(portageq best_version / "$atom" 2>/dev/null || true)
    case "$have" in
        *-"$want"*) ;;
        "") warn "$atom is not installed" ;;
        *) warn "patches were made against ${atom#*/} $want but $have is installed; if the build fails at the patch step, the patch needs refreshing" ;;
    esac
done

# the fixes plasma-glass's patches held until 2026-10-17 (kwin-fixes.patch, and the notification body's
# cursor in plasma-workspace-tweaks.patch): without kde-fixes, the next build of those packages goes
# without them
if [ ! -e /etc/portage/patches/kde-plasma/kwin/kwin-activation-token-serial.patch ]; then
    warn "kde-fixes isn't installed: KWin's and Qt's bug fixes moved there (frame pacing, the crash at logout,
  activation tokens, KSvg's colours, Qt's resize glitches). Install them with its install.sh:
  git clone git@github.com:Alex-Aralis/kde-fixes.git && sudo kde-fixes/install.sh"
fi

if [ "$REBUILD" = 1 ] && [ -n "$rebuild" ]; then
    say "Rebuilding$rebuild (plasma-workspace, kwin and plasma-desktop take a while)"
    # shellcheck disable=SC2086
    emerge --oneshot --verbose $rebuild
elif [ "$REBUILD" = 1 ]; then
    say "Every patched package is already built with its current patch"
fi

# --- 3. The Liquid Glass effect ------------------------------------------------------------------
say "Liquid Glass effect (a KWin plugin of its own)"
share=/usr/local/share/plasma-glass
rm -rf "${share:?}/kwin-effect" && mkdir -p "$share/tools"
cp -r "$REPO/kwin-effect" "$share/" && install -m 755 "$REPO/tools/kwin-effect.sh" "$share/tools/"
hook=/etc/portage/env/kde-plasma/kwin
if [ -e "$hook" ] && ! grep -q '^# plasma-glass' "$hook"; then
    warn "$hook is someone else's: not replaced. KWin updates won't rebuild the effect (run $share/tools/kwin-effect.sh install after one)"
else
    install -D -m 644 "$REPO/kwin-effect/portage-hook.sh" "$hook"
fi
XDG_CACHE_HOME=/var/cache/plasma-glass "$share/tools/kwin-effect.sh" install || die "the Liquid Glass effect didn't build"

# --- done -----------------------------------------------------------------------------------------
render=$(ls -l /dev/dri/renderD128 2>/dev/null || true)
cat <<EOF

Done. As your normal user:
  - restart Plasma's shell and KRunner to load the patched builds:
        systemctl --user restart plasma-plasmashell.service; kquitapp6 krunner
  - swap the Liquid Glass effect into KWin in place of its blur (./install.sh does it, now and for later logins):
        tools/kwin-effect.sh enable; tools/kwin-effect.sh reload
  - restart the search service so it picks up the GPU:
        systemctl --user restart embedsearch
EOF
case "$render" in
    *rw-rw-rw-*) ;;
    *) echo "If the GPU still isn't used, check your user can open /dev/dri/renderD128 (usually the 'render' or 'video' group): $render" ;;
esac
