#!/usr/bin/env bash
# Build a release: packages src/ into releases/WallFramer_vX.Y.Z.rbz and
# updates version.json so every SketchUp running Wall Framer sees the update.
#   scripts/build.sh "What changed in this version"
set -euo pipefail
cd "$(dirname "$0")/.."
# Guard: never ship a file that won't load (0.18.1 shipped with a syntax error)
for f in src/dmacc_wall_framer.rb src/dmacc_wall_framer/*.rb; do
  ruby -c "$f" > /dev/null || { echo "Syntax error in $f - not building."; exit 1; }
done
if command -v node > /dev/null; then
  for h in src/dmacc_wall_framer/html/*.html; do
    python3 -c "import re,sys; s=open(sys.argv[1]).read(); print('\n'.join(re.findall(r'<script>(.*?)</script>', s, re.S)))" "$h" > /tmp/wf_check.js
    node --check /tmp/wf_check.js || { echo "Script error in $h - not building."; exit 1; }
  done
fi
timeout 120 ruby -Itest/stubs test/smoke.rb > /tmp/wf_smoke.log 2>&1 || { echo "Extension doesn't load in the smoke test - not building (see /tmp/wf_smoke.log)."; exit 1; }
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
