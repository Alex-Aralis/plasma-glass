#!/bin/sh
# Switches the desktop between dark and light by applying the Liquid Glass (or Liquid Glass Dark Frost) or Liquid
# Glass Light global theme (theme/look-and-feel: Breeze Dark's or Breeze's colours, icons, cursor and window
# decorations, with the Liquid Glass Plasma Style; KWin's glass follows the style, frosted lightly with a bevel on
# dark, frosted with the waves beneath on light and on Dark Frost). They are also KDE's default dark and light global
# themes (install.sh), so its own Dark Mode switch (the tray's Brightness and Color, Quick Settings) does the same:
# the dark one last picked here (or by install.sh) is the one it goes to, and so does the toggle from light.
# Installed as plasma-glass-mode, with a "Toggle Dark/Light Mode" launcher for KRunner and the start menu.
#   plasma-glass-mode                         toggle
#   plasma-glass-mode dark|dark-frost|light   set one
set -eu

current=$(kreadconfig6 --file plasmarc --group Theme --key name)
dark=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel)
[ "$dark" = plasma-glass.liquid-glass-dark-frost ] || dark=plasma-glass.liquid-glass
case "${1:-toggle}" in
    dark) package=plasma-glass.liquid-glass ;;
    dark-frost) package=plasma-glass.liquid-glass-dark-frost ;;
    light) package=plasma-glass.liquid-glass-light ;;
    toggle) case "$current" in liquid-glass-light) package=$dark ;; *) package=plasma-glass.liquid-glass-light ;; esac ;;
    *) echo "usage: plasma-glass-mode [dark|dark-frost|light]" >&2; exit 2 ;;
esac
mode=${package#plasma-glass.liquid-glass-}
[ "$mode" != "$package" ] || mode=dark

[ "$mode" = light ] || kwriteconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel "$package"
plasma-apply-lookandfeel --apply "$package" >/dev/null 2>&1
echo "$mode"
