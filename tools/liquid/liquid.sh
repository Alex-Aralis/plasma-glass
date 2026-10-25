#!/bin/sh
# tools/liquid/liquid.py (the numpy model of the Liquid Glass liquid) in a venv of its own with numpy and
# Pillow, made in ~/.cache/plasma-glass/liquid on first use. Arguments go to liquid.py: drag, click, check,
# compare (see README.md).
set -eu
VENV="${XDG_CACHE_HOME:-$HOME/.cache}/plasma-glass/liquid/venv"
if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c 'import numpy, PIL' 2>/dev/null; then
    python3 -m venv "$VENV" && "$VENV/bin/pip" install -q numpy pillow >&2 || { echo "error: could not set up $VENV" >&2; exit 1; }
fi
exec "$VENV/bin/python" -I "$(cd "$(dirname "$0")" && pwd)/liquid.py" "$@"
