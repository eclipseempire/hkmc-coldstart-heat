#!/bin/bash
# Build + sign the Cold-start Heat settings APK (com.nemesis.coldstart).
#
# Requirements:
#   - A JDK (javac, keytool)
#   - Android build-tools (aapt, dx, zipalign, apksigner) and a platform android.jar
#
# Set these env vars (defaults assume a standard SDK layout):
#   ANDROID_SDK   path to your Android SDK root        (required)
#   BUILD_TOOLS   build-tools version   (default 30.0.3 - must still ship `dx`)
#   PLATFORM      platform for android.jar (default android-30)
#
# NOTE: this uses the legacy `dx` dexer, not `d8`. `d8`/`r8` from older
# build-tools crash under very new JDKs (e.g. JDK 27). `dx` emits DEX 035,
# which the KitKat-based Gen5W head unit requires anyway.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${ANDROID_SDK:?set ANDROID_SDK to your Android SDK root}"
: "${BUILD_TOOLS:=30.0.3}"
: "${PLATFORM:=android-30}"
BT="$ANDROID_SDK/build-tools/$BUILD_TOOLS"
AJ="$ANDROID_SDK/platforms/$PLATFORM/android.jar"
APP="$ROOT/app"
OUT="$APP/build"
KS="$APP/debug.jks"

[ -x "$BT/dx" ] || { echo "no dx in $BT (use a build-tools that still ships dx, e.g. 30.0.3)"; exit 1; }
[ -f "$AJ" ] || { echo "no android.jar at $AJ"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT/classes"

echo "== javac =="
javac --release 8 -classpath "$AJ" -d "$OUT/classes" $(find "$APP/src" -name '*.java')

echo "== dex (dx, min-sdk 19) =="
"$BT/dx" --dex --min-sdk-version=19 --output="$OUT/classes.dex" "$OUT/classes"

echo "== package manifest =="
"$BT/aapt" package -f -M "$APP/AndroidManifest.xml" -I "$AJ" -F "$OUT/base.apk"
( cd "$OUT" && "$BT/aapt" add base.apk classes.dex >/dev/null )

echo "== align =="
"$BT/zipalign" -f 4 "$OUT/base.apk" "$OUT/aligned.apk"

echo "== sign (v1 required for KitKat) =="
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -storepass android -keypass android \
    -alias cs -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=coldstart" >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --v1-signing-enabled true --v2-signing-enabled true --min-sdk-version 19 \
  --out "$APP/coldstart.apk" "$OUT/aligned.apk"

echo "== done: $APP/coldstart.apk =="
"$BT/aapt" dump badging "$APP/coldstart.apk" 2>/dev/null | grep -E "package|sdkVersion" | head
echo "Copy app/coldstart.apk to package/app/coldstart.apk, then build the NEMESIS zip."
