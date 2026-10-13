#!/bin/sh
# KRunner and Plasma settings used with plasma-glass. Safe to re-run.
set -e

# KRunner: floating in the middle of the screen instead of hanging from the top edge
kwriteconfig6 --file krunnerrc --group General --key FreeFloating true
# Where it floats (needs the plasma-workspace patch): top edge at 20% of the screen height, centre at
# 62% of the width, unless it has been placed already (dragging KRunner saves its spot here).
[ -n "$(kreadconfig6 --file krunnerrc --group General --key FloatingTop)" ] ||
    kwriteconfig6 --file krunnerrc --group General --key FloatingTop 0.2
[ -n "$(kreadconfig6 --file krunnerrc --group General --key FloatingCenterX)" ] ||
    kwriteconfig6 --file krunnerrc --group General --key FloatingCenterX 0.62

# KRunner opens with Meta+Space (like Spotlight) instead of Alt+Space; Alt+F2 and Search stay
sh "$(dirname "$0")/krunner-shortcut.sh" meta

# KRunner plugins: no browser history/tabs flood, no help plugin (hides the "?" button)
kwriteconfig6 --file krunnerrc --group Plugins --key browserhistoryEnabled false
kwriteconfig6 --file krunnerrc --group Plugins --key browsertabsEnabled false
kwriteconfig6 --file krunnerrc --group Plugins --key helprunnerEnabled false

# Favourites rank first, in this order (KRunner and the Kickoff start menu both read this)
kwriteconfig6 --file krunnerrc --group Plugins --group Favorites --key plugins \
    "krunner_sessions,krunner_powerdevil,krunner_systemsettings,krunner_services"

# Notification popups: no countdown bar along the top
kwriteconfig6 --file plasmanotifyrc --group Notifications --key ShowPopupTimeout false --notify

# Hides KRunner's settings (gear) button. Side effect: the KRunner page in System Settings is hidden
# too; remove this key from ~/.config/kdeglobals to get it back.
kwriteconfig6 --file kdeglobals --group "KDE Control Module Restrictions" --key kcm_krunnersettings false
