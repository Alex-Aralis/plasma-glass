#!/bin/sh
# Switches the desktop between dark and light by applying the Liquid Glass or Liquid Glass Light global theme
# (theme/look-and-feel: Breeze Dark's or Breeze's colours, icons, cursor and window decorations, with the Liquid
# Glass Plasma Style; KWin's glass follows the style, frosted lightly with a bevel on dark, frosted with the
# waves beneath on light). They are also KDE's default dark and light global themes (install.sh), so its own
# Dark Mode switch (the tray's Brightness and Color, Quick Settings) does the same. Installed as
# plasma-glass-mode, with a "Toggle Dark/Light Mode" launcher for KRunner and the start menu.
#   plasma-glass-mode              toggle
#   plasma-glass-mode dark|light   set one
set -eu

current=$(kreadconfig6 --file plasmarc --group Theme --key name)
case "${1:-toggle}" in
    dark | light) mode=$1 ;;
    toggle) case "$current" in liquid-glass-light) mode=dark ;; *) mode=light ;; esac ;;
    *) echo "usage: plasma-glass-mode [dark|light]" >&2; exit 2 ;;
esac

if [ "$mode" = light ]; then package=plasma-glass.liquid-glass-light; else package=plasma-glass.liquid-glass; fi
plasma-apply-lookandfeel --apply "$package" >/dev/null 2>&1
echo "$mode"
