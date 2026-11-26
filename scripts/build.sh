#!/usr/bin/env bash
# Build a release: packages src/ into releases/WallFramer_vX.Y.Z.rbz and
# updates version.json so every SketchUp running Wall Framer sees the update.
#   scripts/build.sh "What changed in this version"
set -euo pipefail
cd "$(dirname "$0")/.."
V=$(sed -n "s/.*VERSION = '\([0-9.]*\)'.*/\1/p" src/dmacc_wall_framer/version.rb)
OUT="releases/WallFramer_v${V}.rbz"
rm -f "$OUT"
(cd src && zip -qr "../$OUT" dmacc_wall_framer.rb dmacc_wall_framer)
cat > version.json <<JSON
{
  "version": "${V}",
  "rbz": "https://raw.githubusercontent.com/adamnegrete-lab/Wall-Framer-Ext./main/${OUT}",
  "notes": "${1:-Wall Framer ${V}}"
}
JSON
echo "Built $OUT and version.json for ${V}"
