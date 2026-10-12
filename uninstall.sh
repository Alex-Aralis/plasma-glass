#!/bin/sh
# Removes the user part of plasma-glass. Pass --keep-index to keep the search index and config.
set -eu
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
KEEP_INDEX=0
[ "${1:-}" = --keep-index ] && KEEP_INDEX=1

systemctl --user disable --now embedsearch.service 2>/dev/null || true
rm -f "$CONF/systemd/user/embedsearch.service" "$DATA/dbus-1/services/local.embedsearch.service" \
      "$DATA/krunner/dbusplugins/embedsearch.desktop" "$HOME/.local/bin/embedsearch"
systemctl --user daemon-reload
if [ "$KEEP_INDEX" = 1 ]; then
    rm -rf "$DATA/embedsearch/venv" "$DATA/embedsearch/ov_cache"
else
    rm -rf "$DATA/embedsearch" "$CONF/embedsearch"
fi

case "$(kreadconfig6 --file plasmarc --group Theme --key name)" in
    liquid-glass*) plasma-apply-desktoptheme default ;;
esac
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
kquitapp6 krunner >/dev/null 2>&1 || true

cat <<'EOF'
User part removed. To undo the system part (as root):
    rm -r /etc/portage/patches/kde-plasma/plasma-workspace /etc/portage/patches/kde-plasma/milou
    emerge --oneshot kde-plasma/milou kde-plasma/plasma-workspace
and, if nothing else needs it, the GPU runtime:
    emerge --ask --depclean dev-libs/intel-compute-runtime virtual/opencl dev-libs/opencl-icd-loader
EOF
