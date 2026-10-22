#!/bin/sh
# Removes the user part of plasma-glass. Pass --keep-index to keep the search index and config.
set -eu
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
KEEP_INDEX=0
[ "${1:-}" = --keep-index ] && KEEP_INDEX=1

systemctl --user disable --now embedsearch.service 2>/dev/null || true
# KRunner's drop-ins from before 2026-10-17 (kde-fixes' now, which has its own uninstall.sh)
rm -f "$CONF/systemd/user/plasma-krunner.service.d/plasma-glass-software-render.conf" \
      "$CONF/systemd/user/plasma-krunner.service.d/plasma-glass-priority.conf"
rm -f "$CONF/systemd/user/embedsearch.service" "$DATA/dbus-1/services/local.embedsearch.service" \
      "$DATA/krunner/dbusplugins/embedsearch.desktop" "$HOME/.local/bin/embedsearch" \
      "$DATA/applications/plasma-glass-index.desktop"
systemctl --user daemon-reload
if [ "$KEEP_INDEX" = 1 ]; then
    rm -rf "$DATA/embedsearch/venv" "$DATA/embedsearch/ov_cache"
else
    rm -rf "$DATA/embedsearch" "$CONF/embedsearch"
fi

# back to Breeze's global themes (the Liquid Glass ones are KDE's default dark and light ones)
case "$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)" in
    plasma-glass.liquid-glass-light) plasma-apply-lookandfeel --apply org.kde.breeze.desktop >/dev/null 2>&1 || true ;;
    plasma-glass.*) plasma-apply-lookandfeel --apply org.kde.breezedark.desktop >/dev/null 2>&1 || true ;;
esac
kwriteconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel --delete
kwriteconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel --delete
case "$(kreadconfig6 --file plasmarc --group Theme --key name)" in
    liquid-glass*) plasma-apply-desktoptheme default ;;
esac
rm -rf "$DATA/plasma/look-and-feel/plasma-glass.liquid-glass" "$DATA/plasma/look-and-feel/plasma-glass.liquid-glass-light"
rm -f "$HOME/.local/bin/plasma-glass-test-notifications" "$DATA/applications/plasma-glass-test-notifications.desktop"
rm -f "$HOME/.local/bin/plasma-glass-tune" "$DATA/applications/plasma-glass-tune.desktop"
rm -f "$HOME/.local/bin/plasma-glass-mode" "$DATA/applications/plasma-glass-mode.desktop"
rm -rf "$DATA/plasma-glass"  # the tuning window; its settings (~/.config/plasma-glassrc) stay
rm -rf "$DATA/plasma/desktoptheme/liquid-glass" "$DATA/plasma/desktoptheme/liquid-glass-light" \
       "${XDG_CACHE_HOME:-$HOME/.cache}"/plasma_theme_liquid-glass*.kcache

# undo desktop/plasma-settings.sh
for key in browserhistoryEnabled browsertabsEnabled helprunnerEnabled; do
    kwriteconfig6 --file krunnerrc --group Plugins --key "$key" --delete
done
kwriteconfig6 --file krunnerrc --group Plugins --group Favorites --key plugins --delete
kwriteconfig6 --file krunnerrc --group General --key FreeFloating --delete
kwriteconfig6 --file krunnerrc --group General --key FloatingTop --delete
kwriteconfig6 --file krunnerrc --group General --key FloatingCenterX --delete
kwriteconfig6 --file kdeglobals --group "KDE Control Module Restrictions" --key kcm_krunnersettings --delete
kwriteconfig6 --file plasmanotifyrc --group Notifications --key ShowPopupTimeout --delete --notify
sh "$(dirname "$0")/desktop/krunner-shortcut.sh" alt
kquitapp6 krunner >/dev/null 2>&1 || true

cat <<'EOF'
User part removed. To undo the system part (as root):
    rm -f /etc/portage/patches/kde-plasma/plasma-workspace/plasma-workspace-tweaks.patch \
          /etc/portage/patches/kde-plasma/milou/milou-section-headers.patch \
          /etc/portage/patches/kde-plasma/kwin/kwin-liquid-glass.patch \
          /etc/portage/patches/kde-plasma/plasma-desktop/plasma-desktop-tweaks.patch
    emerge --oneshot kde-plasma/milou kde-plasma/plasma-workspace kde-plasma/kwin kde-plasma/plasma-desktop
(kde-fixes' patches for the same packages stay; its uninstall.sh removes them)
and, if nothing else needs it, the GPU runtime:
    emerge --ask --depclean dev-libs/intel-compute-runtime virtual/opencl dev-libs/opencl-icd-loader
EOF
