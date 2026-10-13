#!/bin/sh
# Moves KRunner's launch shortcut between Alt+Space (Plasma's) and Meta+Space (plasma-glass's, like
# Spotlight), keeping its other keys (Alt+F2, Search). Usage: krunner-shortcut.sh meta|alt
# kglobalaccel owns kglobalshortcutsrc while a session runs, so ask it then; else edit the file.
set -e
META=268435488 ALT=134217760   # Qt::META|Qt::Key_Space, Qt::ALT|Qt::Key_Space
case "${1:-}" in
    meta) new=$META old=$ALT name=Meta+Space oldname=Alt+Space ;;
    alt) new=$ALT old=$META name=Alt+Space oldname=Meta+Space ;;
    *) echo "usage: $0 meta|alt" >&2; exit 2 ;;
esac

id='array:string:org.kde.krunner.desktop,_launch,KRunner,Launch KRunner'
accel() { dbus-send --session --print-reply=literal --dest=org.kde.kglobalaccel /kglobalaccel "org.kde.KGlobalAccel.$@"; }
if keys=$(accel shortcut "$id" 2>/dev/null); then
    # isGlobalShortcutAvailable says no even when KRunner itself has the key, so ask who has it
    owner=$(accel action int32:$new | awk '$1 != "array" && NF > 1 { print $1 }')
    if [ -z "$owner" ] || [ "$owner" = org.kde.krunner.desktop ]; then
        keys=$(printf '%s\n' "$keys" | awk -v a=$old -v b=$new '$1 == "int32" && $2 != a && $2 != b { printf ",%s", $2 }')
        accel setForeignShortcut "$id" "array:int32:$new$keys" >/dev/null
    else
        echo "warning: $name already opens $owner; KRunner keeps its shortcuts" >&2
    fi
else
    tab=$(printf '\t')
    keys=$(kreadconfig6 --file kglobalshortcutsrc --group services --group org.kde.krunner.desktop --key _launch)
    keys=$(printf '%s\n' "${keys:-Alt+Space${tab}Alt+F2${tab}Search}" | tr '\t' '\n' |
        grep -vxF -e "$oldname" -e "$name" -e none | paste -sd "$tab" -)
    kwriteconfig6 --file kglobalshortcutsrc --group services --group org.kde.krunner.desktop --key _launch \
        "$name${keys:+$tab$keys}"
fi
