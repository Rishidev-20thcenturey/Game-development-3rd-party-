#!/usr/bin/env bash
# Build a signed, installable APK of Turbo Kart Rally.
#
#   ./games/turbo-kart-rally/build-apk.sh
#
# No Android Studio / SDK / Gradle needed: tools/android/fetch-toolchain.sh downloads a small
# pinned toolchain (JRE, aapt2, android.jar, ecj, dx, apksigner) on first run.
#
# Environment overrides:
#   VERSION_NAME / VERSION_CODE   app version (default 1.0.0 / 1)
#   KEYSTORE, KEYSTORE_PASS, KEY_ALIAS, KEY_PASS
#       release keystore. If KEYSTORE is unset, a local key is generated in
#       .cache/keystore/ (fine for previews; use your own private key for store releases).
#   OUT_DIR                       where the APK goes (default: <repo>/downloads)
set -euo pipefail

GAME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$GAME_DIR/../.." && pwd)"
TC="${TOOLCHAIN_DIR:-$REPO_ROOT/.cache/android-toolchain}"
BUILD="$REPO_ROOT/.cache/build/turbo-kart-rally"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/downloads}"

APP_NAME="TurboKartRally"
VERSION_NAME="${VERSION_NAME:-1.0.0}"
VERSION_CODE="${VERSION_CODE:-1}"
MIN_SDK=24
TARGET_SDK=35

log() { printf '\033[1;32m[apk]\033[0m %s\n' "$*"; }

TOOLCHAIN_DIR="$TC" bash "$REPO_ROOT/tools/android/fetch-toolchain.sh"
JAVA="$TC/jre/bin/java"

rm -rf "$BUILD" && mkdir -p "$BUILD/assets/www" "$BUILD/classes" "$OUT_DIR"

# ---- 1. web game -> assets/www ------------------------------------------------------------------
log "staging web game"
cp -R "$GAME_DIR/web/." "$BUILD/assets/www/"
find "$BUILD/assets/www" -name '.DS_Store' -delete
cp "$GAME_DIR/LICENSE" "$BUILD/assets/www/LICENSE.txt"
cp "$GAME_DIR/THIRD_PARTY_NOTICES.md" "$BUILD/assets/www/THIRD_PARTY_NOTICES.md"

# ---- 2. resources + manifest (aapt2) -----------------------------------------------------------
log "compiling resources"
"$TC/aapt2" compile --dir "$GAME_DIR/android/res" -o "$BUILD/res.zip"
log "linking manifest + resources + assets"
"$TC/aapt2" link -o "$BUILD/base.apk" \
  -I "$TC/android.jar" \
  --manifest "$GAME_DIR/android/AndroidManifest.xml" \
  --min-sdk-version "$MIN_SDK" --target-sdk-version "$TARGET_SDK" \
  --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" \
  -A "$BUILD/assets" \
  "$BUILD/res.zip"

# ---- 3. Java -> classes.dex (ecj + dx) ---------------------------------------------------------
log "compiling MainActivity"
find "$GAME_DIR/android/java" -name '*.java' > "$BUILD/sources.txt"
"$JAVA" -jar "$TC/ecj.jar" -source 1.6 -target 1.6 -encoding UTF-8 -nowarn \
  -bootclasspath "$TC/android.jar" -d "$BUILD/classes" @"$BUILD/sources.txt" 2>&1 \
  | grep -v 'Annotation processing got disabled' || true
[ -f "$BUILD/classes/com/rishidev/turbokartrally/MainActivity.class" ] || { echo "java compile failed" >&2; exit 1; }
log "dexing"
"$JAVA" -jar "$TC/dx.jar" --dex --output="$BUILD/classes.dex" "$BUILD/classes"

python3 - "$BUILD/base.apk" "$BUILD/classes.dex" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a', zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[2], 'classes.dex')
PY

# ---- 4. align + sign ----------------------------------------------------------------------------
log "aligning"
python3 "$REPO_ROOT/tools/android/zipalign.py" "$BUILD/base.apk" "$BUILD/aligned.apk"

if [ -z "${KEYSTORE:-}" ]; then
  KEYSTORE="$REPO_ROOT/.cache/keystore/turbo-kart-rally-preview.jks"
  KEYSTORE_PASS="${KEYSTORE_PASS:-tkr-preview-pass}"
  KEY_ALIAS="${KEY_ALIAS:-tkr}"
  if [ ! -f "$KEYSTORE" ]; then
    log "generating local preview signing key ($KEYSTORE)"
    mkdir -p "$(dirname "$KEYSTORE")"
    "$TC/jre/bin/keytool" -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 \
      -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" -alias "$KEY_ALIAS" \
      -keyalg RSA -keysize 3072 -validity 10000 \
      -dname "CN=Turbo Kart Rally (preview build), O=Game-development-3rd-party, C=IN" >/dev/null
  fi
fi
KEY_ALIAS="${KEY_ALIAS:-tkr}"
KEY_PASS="${KEY_PASS:-$KEYSTORE_PASS}"

APK="$OUT_DIR/$APP_NAME-v$VERSION_NAME.apk"
log "signing (v1 + v2 + v3)"
"$JAVA" -jar "$TC/apksigner.jar" sign \
  --ks "$KEYSTORE" --ks-pass "pass:$KEYSTORE_PASS" --ks-key-alias "$KEY_ALIAS" --key-pass "pass:$KEY_PASS" \
  --min-sdk-version "$MIN_SDK" \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$APK" "$BUILD/aligned.apk"
rm -f "$APK.idsig"

log "verifying"
"$JAVA" -jar "$TC/apksigner.jar" verify --min-sdk-version "$MIN_SDK" --verbose "$APK" | head -8
python3 "$REPO_ROOT/tools/android/zipalign.py" --check "$APK" && log "alignment OK"
"$TC/aapt2" dump badging "$APK" | sed -n 1,3p

( cd "$OUT_DIR" && sha256sum "$(basename "$APK")" > "$(basename "$APK").sha256" )
log "done: $APK ($(du -h "$APK" | cut -f1))"
