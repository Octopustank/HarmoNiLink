#!/bin/bash
# sign.sh — Build & sign NiLink release artifacts (.hap + .app)
# First time: cp .env.example .env and fill in the real values (secrets stay
# gitignored). Expects certificates under signing/ and the API-26 toolchain.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Load env
set -a; source .env; set +a

# hap-sign-tool.jar ships inside the SDK toolchains. Always resolve from the
# API-26 bundle (ignore any inherited OHOS_CLI_HOME, which may point elsewhere).
CLT_HOME="$(ls -d "$HOME"/.local/share/harmonyos/cli-tools-* 2>/dev/null | while IFS= read -r d; do grep -q '"apiVersion": "26"' "$d/command-line-tools/sdk/default/sdk-pkg.json" 2>/dev/null && { echo "$d"; break; }; done)"
TOOL="$CLT_HOME/command-line-tools/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
[ -f "$TOOL" ] || { echo "ERROR: hap-sign-tool.jar (API 26) not found under $CLT_HOME" >&2; exit 1; }
OUT_DIR="build/outputs/default"
U_HAP="entry/build/default/outputs/default/entry-default-unsigned.hap"
S_HAP="${U_HAP%.hap}-signed.hap"
U_APP="$OUT_DIR/HarmoNiLink-default-unsigned.app"
S_APP="$OUT_DIR/HarmoNiLink-default-signed.app"

echo "=== 1. Build HAP (release) ==="
# --no-daemon: the hvigor daemon registry is unreliable in this env (stale
# daemon-sec.json from killed daemons breaks lock acquisition). Non-daemon
# build is marginally slower but deterministic.
hvigorw --no-daemon assembleHap --mode module -p module=entry@default -p product=default -p buildMode=release

echo "=== 2. Sign HAP ==="
java -jar "$TOOL" sign-app -mode localSign \
  -keyAlias "${SIGN_KEY_ALIAS:-NiLink-Release}" \
  -keyPwd "$SIGN_KEYSTORE_PASS" \
  -appCertFile "${SIGN_CERT_FILE:-./signing/Release_Cert.cer}" \
  -profileFile "${SIGN_PROFILE_FILE:-./signing/NiLink_ProfileRelease.p7b}" \
  -inFile "$U_HAP" \
  -signAlg "${SIGN_ALG:-SHA256withECDSA}" \
  -keystoreFile "${SIGN_KEYSTORE_FILE:-./signing/NiLink.p12}" \
  -keystorePwd "$SIGN_KEYSTORE_PASS" \
  -outFile "$S_HAP" \
  -compatibleVersion "${SIGN_COMPAT_VERSION:-23}" -signCode 1

echo "=== 3. Build APP + repack ==="
hvigorw --no-daemon assembleApp -p product=default -p buildMode=release
TMP=$(mktemp -d)
unzip -o "$U_APP" -d "$TMP" >/dev/null
cp "$S_HAP" "$TMP/entry-default.hap"
cd "$TMP" && zip -qr unsigned-repacked.app . && cd "$SCRIPT_DIR"

echo "=== 4. Sign APP ==="
java -jar "$TOOL" sign-app -mode localSign \
  -keyAlias "${SIGN_KEY_ALIAS:-NiLink-Release}" \
  -keyPwd "$SIGN_KEYSTORE_PASS" \
  -appCertFile "${SIGN_CERT_FILE:-./signing/Release_Cert.cer}" \
  -profileFile "${SIGN_PROFILE_FILE:-./signing/NiLink_ProfileRelease.p7b}" \
  -inFile "$TMP/unsigned-repacked.app" \
  -signAlg "${SIGN_ALG:-SHA256withECDSA}" \
  -keystoreFile "${SIGN_KEYSTORE_FILE:-./signing/NiLink.p12}" \
  -keystorePwd "$SIGN_KEYSTORE_PASS" \
  -outFile "$S_APP" \
  -compatibleVersion "${SIGN_COMPAT_VERSION:-23}" -signCode 1

rm -rf "$TMP"
cp "$S_HAP" "$OUT_DIR/HarmoNiLink-default-signed.hap"
echo "=== Done ==="
ls -lh "$OUT_DIR/HarmoNiLink-default-signed.hap" "$S_APP"