#!/bin/sh
# plasma-glass installer, system part (Gentoo). Run as root from the repo:
#
#   sudo ./install-system.sh                   GPU compute runtime + Portage patches + rebuild
#   sudo ./install-system.sh --help            options
#
# 1. Intel GPU compute runtime (OpenCL/Level Zero) so OpenVINO can run the search model on the iGPU.
# 2. Portage user patches for kde-plasma/plasma-workspace (KRunner + notification popups) and
#    kde-plasma/milou (KRunner result rows), then rebuilds both. Portage re-applies the patches on
#    every future update of those packages.
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
        install the Portage patches but don't rebuild plasma-workspace and milou now
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
    say "Checking the patches against your installed Plasma (about 10-30 s)"
    sh "$REPO/tools/check-patches.sh" || die "patch checks failed; nothing was installed (override with --skip-checks)"
fi
say "Installing Portage user patches"
for pkg in plasma-workspace milou; do
    dest=/etc/portage/patches/kde-plasma/$pkg
    mkdir -p "$dest"
    # names used by earlier versions of these patches
    rm -f "$dest/krunner-hide-pin.patch" "$dest/krunner-tweaks.patch"
    install -m 644 "$REPO"/patches/kde-plasma/$pkg/*.patch "$dest/"
    echo "  $dest: $(cd "$dest" && ls)"
done
for pkg in plasma-workspace milou; do
    have=$(portageq best_version / kde-plasma/$pkg 2>/dev/null || true)
    case "$have" in
        *-6.7.5*) ;;
        "") warn "kde-plasma/$pkg is not installed" ;;
        *) warn "patches were made against $pkg 6.7.5 but $have is installed; if the build fails at the patch step, the patch needs refreshing" ;;
    esac
done

if [ "$REBUILD" = 1 ]; then
    say "Rebuilding milou and plasma-workspace (plasma-workspace is a long compile)"
    emerge --oneshot --verbose kde-plasma/milou kde-plasma/plasma-workspace
fi

# --- done -----------------------------------------------------------------------------------------
render=$(ls -l /dev/dri/renderD128 2>/dev/null || true)
cat <<EOF

Done. As your normal user, restart Plasma's shell and KRunner to load the patched builds:
    systemctl --user restart plasma-plasmashell.service; kquitapp6 krunner
and the search service so it picks up the GPU:
    systemctl --user restart embedsearch
EOF
case "$render" in
    *rw-rw-rw-*) ;;
    *) echo "If the GPU still isn't used, check your user can open /dev/dri/renderD128 (usually the 'render' or 'video' group): $render" ;;
esac
