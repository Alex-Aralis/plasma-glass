#!/bin/sh
# Puts plasma-glass's app grid (theme/icons, installed by install.sh) on the start menu's button in place
# of the Plasma logo, or the logo back. Usage: kickoff-icon.sh grid|plasma
# A start menu with an icon of your own keeps it. Plasma's scripting changes the running panels, so this
# needs plasmashell; without it nothing changes.
set -e
case "${1:-}" in
    grid) new=plasmaglass-app-grid-symbolic old="start-here-kde-symbolic start-here-kde-plasma-symbolic start-here-kde" ;;
    plasma) new=start-here-kde-symbolic old=plasmaglass-app-grid-symbolic ;;
    *) echo "usage: $0 grid|plasma" >&2; exit 2 ;;
esac

script="const old = '$old'.split(' ');
for (const panel of panels()) {
    for (const kickoff of panel.widgets('org.kde.plasma.kickoff')) {
        kickoff.currentConfigGroup = ['General'];
        const icon = String(kickoff.readConfig('icon', ''));
        if (icon === '' || old.includes(icon)) {
            kickoff.writeConfig('icon', '$new');
        }
    }
}"
qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$script" >/dev/null 2>&1 ||
    echo "warning: plasmashell isn't running, so the start menu keeps its icon (run $0 $1 in your session)" >&2
