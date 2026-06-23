#!/bin/sh
# Smoke test: Metal backend renders Demo.Demo without the P8 sky placeholder (magenta).
# Requires: built PoseidonGame, ~/cwa-remaster (or OFPR_GAME_DIR), python3 + Pillow.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PRESET="${PRESET:-mac-arm64-clang-rwdi}"
BIN="$ROOT/build/$PRESET/apps/cwr/Game/PoseidonGame"
DATA="${OFPR_GAME_DIR:-$HOME/cwa-remaster}"
OUT="${TMPDIR:-/tmp}/metal-demo-smoke-$$.png"

if [ ! -x "$BIN" ]; then
    echo "SKIP: PoseidonGame not found at $BIN"
    exit 0
fi
if [ ! -d "$DATA/Missions/Demo.Demo" ]; then
    echo "SKIP: game data not found at $DATA"
    exit 0
fi

"$BIN" -C "$DATA" --window --no-splash --render metal \
    --test-mission "$DATA/Missions/Demo.Demo" \
    --test-type screenshot -s "$OUT" --screenshot-delay 60 \
    2>&1 | tail -5

python3 - "$OUT" << 'PY'
import sys
from PIL import Image

path = sys.argv[1]
img = Image.open(path).convert("RGB")
w, h = img.size

def count_magenta(y0, y1):
    n = mag = 0
    for y in range(y0, y1):
        for x in range(w):
            r, g, b = img.getpixel((x, y))
            n += 1
            if r > 200 and g < 80 and b > 200:
                mag += 1
    return mag, n

sky_mag, sky_n = count_magenta(0, h // 4)
sky_px = img.getpixel((w // 2, h // 8))
# Bottom strip should show grass/terrain (not sky dome); center may hit the soldier.
grass_px = img.getpixel((w // 4, 7 * h // 8))

print(f"screenshot: {path}")
print(f"sky sample (mid-top): RGB{sky_px}")
print(f"grass sample (lower-left): RGB{grass_px}")
print(f"magenta pixels in top quarter: {sky_mag}/{sky_n} ({100*sky_mag/sky_n:.1f}%)")

# Sky dome should not use the P8-decode placeholder (~82% magenta before fix).
if sky_mag > sky_n * 0.5:
    print("FAIL: sky region still mostly magenta (P8/sky texture decode)")
    sys.exit(1)
# Grass/terrain in the lower view should not be the placeholder either.
if grass_px[0] > 200 and grass_px[1] < 80 and grass_px[2] > 200:
    print("FAIL: grass sample is magenta")
    sys.exit(1)
print("PASS: sky and terrain samples look plausible")
PY

rm -f "$OUT"
echo "metal demo render smoke: OK"
