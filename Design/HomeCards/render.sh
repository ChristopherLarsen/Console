#!/bin/bash
# Renders every preview page to images/ at 2x, sized to its own content height.
set -e
cd "$(dirname "$0")"

# Chrome binary: $CHROME overrides, then standard install locations.
CHROME="${CHROME:-}"
if [ -z "$CHROME" ]; then
  for candidate in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    if [ -x "$candidate" ]; then
      CHROME="$candidate"
      break
    fi
  done
fi
if [ -z "$CHROME" ]; then
  echo "error: Google Chrome not found. Install Chrome or set CHROME=/path/to/chrome binary." >&2
  exit 1
fi
for f in preview/*-light.html preview/*-dark.html; do
  base=$(basename "$f" .html)
  board=${base%-*}
  case "$board" in
    Main)         w=1000 ;;
    Audit)        w=940  ;;
    Chrome)       w=1180 ;;
    *)            w=1300 ;;
  esac
  h=$("$CHROME" --headless --disable-gpu --virtual-time-budget=1500 --window-size=$w,900 \
        --dump-dom "file://$PWD/$f" 2>/dev/null | grep -o '<title>H[0-9]*</title>' | grep -o '[0-9][0-9]*' | head -1)
  [ -z "$h" ] && h=1200
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --virtual-time-budget=1500 --window-size=$w,$h \
    --screenshot="images/$base.png" "file://$PWD/$f" >/dev/null 2>&1
  echo "$base  ${w}x${h}"
done
