#!/bin/sh
# Launch the native macOS arm64 PoseidonGame against a game-data directory.
# Usage: ./run-mac.sh [DATA_DIR] [extra PoseidonGame args...]
# Default DATA_DIR is the SteamCMD-downloaded Remaster Demo (~/cwa-remaster).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${1:-$HOME/cwa-remaster}"
[ "$#" -gt 0 ] && shift || true

BIN="$HERE/build/mac-arm64-clang-rwdi/apps/cwr/Game/PoseidonGame"
if [ ! -x "$BIN" ]; then
    echo "Game binary not found at $BIN — build it first:"
    echo "  VCPKG_ROOT=\$HOME/vcpkg cmake --preset mac-arm64-clang-rwdi"
    echo "  cmake --build build/mac-arm64-clang-rwdi --target PoseidonGame"
    exit 1
fi
if [ ! -d "$DATA_DIR" ]; then
    echo "Data dir not found: $DATA_DIR"
    exit 1
fi

echo "Launching against: $DATA_DIR"
exec "$BIN" -C "$DATA_DIR" --window "$@"
