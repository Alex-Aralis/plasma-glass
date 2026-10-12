#!/bin/sh
# KRunner and Plasma settings used with plasma-glass. Safe to re-run.
set -e

# KRunner: floating in the middle of the screen instead of hanging from the top edge
kwriteconfig6 --file krunnerrc --group General --key FreeFloating true
# Where it floats (needs the plasma-workspace patch): top edge at 20% of the screen height, centre at
# 62% of the width. Tweak freely; KRunner picks changes up on its next start (kquitapp6 krunner).
kwriteconfig6 --file krunnerrc --group General --key FloatingTop 0.2
kwriteconfig6 --file krunnerrc --group General --key FloatingCenterX 0.62

# KRunner plugins: no browser history/tabs flood, no help plugin (hides the "?" button)
kwriteconfig6 --file krunnerrc --group Plugins --key browserhistoryEnabled false
kwriteconfig6 --file krunnerrc --group Plugins --key browsertabsEnabled false
kwriteconfig6 --file krunnerrc --group Plugins --key helprunnerEnabled false

# Favourites rank first, in this order (KRunner and the Kickoff start menu both read this)
kwriteconfig6 --file krunnerrc --group Plugins --group Favorites --key plugins \
    "krunner_sessions,krunner_powerdevil,krunner_systemsettings,krunner_services"

# Hides KRunner's settings (gear) button. Side effect: the KRunner page in System Settings is hidden
# too; remove this key from ~/.config/kdeglobals to get it back.
kwriteconfig6 --file kdeglobals --group "KDE Control Module Restrictions" --key kcm_krunnersettings false
