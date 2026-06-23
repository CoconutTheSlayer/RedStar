#!/usr/bin/env bash
# compare-renderers.sh — capture matched screenshots from the Metal and GL33
# backends for side-by-side comparison.
#
# Usage:
#   ./compare-renderers.sh [outdir] [delay1 delay2 ...]
#
# Defaults: outdir=./render-compare, delays="200 400 600 800".
# Each delay is in render frames after the mission enters gameplay.  Note the
# Demo intro is a real-time cutscene, so the same delay can land on slightly
# different camera positions between runs — this is for eyeballing rendering
# quality (textures / shadows / AA / colour), not pixel-exact diffing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
GAME="$ROOT/build/mac-arm64-clang-rwdi/apps/cwr/Game/PoseidonGame"
DATA="$HOME/cwa-remaster"
MISSION="$DATA/Missions/Demo.Demo"
SHOT="$DATA/tmp/test_screenshot.png"

OUTDIR="${1:-$ROOT/render-compare}"
shift || true
DELAYS=("${@:-200 400 600 800}")
# Re-split if passed as a single string.
if [ "${#DELAYS[@]}" -eq 1 ]; then read -r -a DELAYS <<< "${DELAYS[0]}"; fi

[ -x "$GAME" ] || { echo "Game not built: $GAME"; exit 1; }
[ -f "$MISSION".intro.sqm ] 2>/dev/null || true
mkdir -p "$OUTDIR"

capture() { # render-backend delay outfile
  local backend="$1" delay="$2" out="$3"
  rm -f "$SHOT"
  "$GAME" -C "$DATA" --render "$backend" --window --no-splash -w 1024 -h 768 \
    --test-mission "$MISSION" --test-type screenshot --screenshot-delay "$delay" \
    > /dev/null 2>&1 || true
  if [ -f "$SHOT" ]; then cp -f "$SHOT" "$out"; echo "  $out"; else echo "  (no shot: $backend @ $delay)"; fi
}

echo "Capturing into $OUTDIR (delays: ${DELAYS[*]})"
for d in "${DELAYS[@]}"; do
  echo "delay $d:"
  capture metal "$d" "$OUTDIR/metal_$d.png"
  capture gl33  "$d" "$OUTDIR/gl33_$d.png"
  # Side-by-side composite when ImageMagick is available.
  if command -v magick >/dev/null 2>&1 && [ -f "$OUTDIR/metal_$d.png" ] && [ -f "$OUTDIR/gl33_$d.png" ]; then
    magick montage -tile 2x1 -geometry +4+4 -label 'gl33' "$OUTDIR/gl33_$d.png" \
           -label 'metal' "$OUTDIR/metal_$d.png" "$OUTDIR/compare_$d.png" 2>/dev/null \
      && echo "  $OUTDIR/compare_$d.png"
  fi
done
echo "Done. Open $OUTDIR to compare."
