#!/bin/bash
# Zip the NEMESIS package (package/) into dist/coldstart.heat.zip, then build a
# ready-to-flash USB bundle. Run tools/build_apk.sh first and copy the signed
# APK to package/app/coldstart.apk.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/package/app/coldstart.apk" ] || {
  echo "missing package/app/coldstart.apk - run tools/build_apk.sh and copy app/coldstart.apk there first"; exit 1; }

mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/coldstart.heat.zip"
( cd "$ROOT/package" && zip -r -X "$ROOT/dist/coldstart.heat.zip" . -x '.*' >/dev/null )
echo "wrote dist/coldstart.heat.zip"

# USB bundle: NEMESIS.data (type=install) at root + the package zip under packages/
TMP="$ROOT/dist/usb-bundle"
rm -rf "$TMP"; mkdir -p "$TMP/packages"
cp "$ROOT/dist/coldstart.heat.zip" "$TMP/packages/coldstart.heat.zip"
cat > "$TMP/NEMESIS.data" <<'EOF'
[nemesis]
version=1.0
type=install
path=packages/coldstart.heat.zip
EOF
rm -f "$ROOT/dist/hkmc-coldstart-heat-USB.zip"
# zip the bundle's contents, not the folder: NEMESIS.data must sit at the top of
# the zip so extracting it (or nempm unpacking it) puts it at the USB root
( cd "$TMP" && zip -r -X "$ROOT/dist/hkmc-coldstart-heat-USB.zip" NEMESIS.data packages >/dev/null )
rm -rf "$TMP"
echo "wrote dist/hkmc-coldstart-heat-USB.zip (extract to a FAT32/exFAT USB root)"
