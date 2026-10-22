#!/bin/sh
# The Liquid Glass effect swapped into a running KWin, as tools/kwin-effect.sh reload does it on your desktop:
# KRunner with results under the built-in blur (OUT-before.png), then two builds of the plugin swapped in one
# after the other, each checked by the build KWin says it runs (OUT.png: the second).
#   tools/preview/effect.sh OUT.png ["query"]
# The builds go to a scratch plugin folder the preview's KWin searches (QT_PLUGIN_PATH), not your system's.
set -eu
. "$(dirname "$0")/common.sh"
OUT=$(realpath -m "${1:?usage: effect.sh OUT.png [query]}"); QUERY="${2-system settings}"
mkdir -p "$WORK"
KWIN_EFFECT= prepare
# it starts on the built-in blur, whether or not the effect is installed
kwriteconfig6 --file "$WORK/cfg/kwinrc" --group Plugins --key blurEnabled true
kwriteconfig6 --file "$WORK/cfg/kwinrc" --group Plugins --key liquidglassEnabled false
root="$WORK/effect" && rm -rf "${root:?}" && mkdir -p "$root/plugins/kwin/effects/plugins" "$root/store"
export KWIN_EFFECT_PLUGINDIR="$root/plugins/kwin/effects/plugins" KWIN_EFFECT_STORE="$root/store"
tool="$REPO/tools/kwin-effect.sh"
first=$("$tool" build) && "$tool" install "$first" >/dev/null
sleep 1  # a new id (seconds)
second=$("$tool" build)
cat >"$WORK/swap.sh" <<SH
set -eu
echo "before: \$(qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded blur) blur"
"$tool" reload
"$tool" install "$second" >/dev/null
"$tool" reload
"$tool" status
SH
export KWIN_ENV="QT_PLUGIN_PATH=$root/plugins ${KWIN_ENV:-}" SESSION_HOOK="$WORK/swap.sh"
run_session krunner "$QUERY"
cat "$WORK/hook.log"
grep -iE 'liquidglass|effect' "$WORK/kwin.log" | grep -v 'Failed to gain' | head -5 || true
crop_to_changes "$OUT" "$WORK/shots/before.png" "${OUT%.png}-before.png"
