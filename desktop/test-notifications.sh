#!/bin/sh
# Sends sample notifications to check the popup style (Liquid Glass, padding, cursor, scrolling).
#   plasma-glass-test-notifications [all|basic|long|image|critical]
send() { notify-send --app-name="plasma-glass" "$@" >/dev/null 2>&1 & }  # --action makes notify-send wait

IMAGE=$(ls -S /usr/share/wallpapers/Next/contents/images*/*.png 2>/dev/null | tail -1)

basic() {
    send --icon=preferences-desktop-theme --action=default=Open \
        "Liquid Glass" "A normal notification. It has a click action, so the pointer turns into a hand."
}
long() {
    send --icon=document-edit "A longer notification" \
        "$(for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "Line $i of a body long enough to scroll inside the popup."; done)"
}
image() {
    send --icon=preferences-desktop-wallpaper ${IMAGE:+--hint=string:image-path:"$IMAGE"} \
        "With an image" "Notifications can carry a picture next to the text."
}
critical() {
    send --urgency=critical --icon=dialog-warning \
        "Critical notification" "Stays until dismissed: click it, middle-click it or swipe it away."
}

case "${1:-all}" in
    all) basic; sleep 0.7; long; sleep 0.7; image; sleep 0.7; critical ;;
    basic|long|image|critical) "$1" ;;
    *) echo "usage: $0 [all|basic|long|image|critical]" >&2; exit 2 ;;
esac
