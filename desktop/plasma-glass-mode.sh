#!/bin/sh
# Switches the desktop between dark and light: the Liquid Glass Plasma Style (KWin's glass follows it,
# frosted lightly with a bevel on dark, frosted with the waves beneath on light), the colour scheme apps
# use (Breeze Dark or Breeze Light) and the icons. Installed as plasma-glass-mode, with a "Toggle Dark/Light
# Mode" launcher for KRunner and the start menu.
#   plasma-glass-mode              toggle
#   plasma-glass-mode dark|light   set one
set -eu

current=$(kreadconfig6 --file plasmarc --group Theme --key name)
case "${1:-toggle}" in
    dark | light) mode=$1 ;;
    toggle) case "$current" in liquid-glass-light) mode=dark ;; *) mode=light ;; esac ;;
    *) echo "usage: plasma-glass-mode [dark|light]" >&2; exit 2 ;;
esac

if [ "$mode" = light ]; then
    style=liquid-glass-light scheme=BreezeLight icons=breeze lookandfeel=org.kde.breeze.desktop
else
    style=liquid-glass scheme=BreezeDark icons=breeze-dark lookandfeel=org.kde.breezedark.desktop
fi

plasma-apply-desktoptheme "$style" >/dev/null
# says so, and fails, when the scheme is already the current one
plasma-apply-colorscheme "$scheme" >/dev/null 2>&1 || true
for changeicons in /usr/libexec/plasma-changeicons /usr/lib64/libexec/plasma-changeicons /usr/lib/libexec/plasma-changeicons; do
    [ -x "$changeicons" ] && { "$changeicons" "$icons" >/dev/null 2>&1 || true; break; }
done
# which global theme System Settings shows as current
kwriteconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage "$lookandfeel"
echo "$mode"
