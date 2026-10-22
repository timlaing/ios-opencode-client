#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
# No shell tracing: the inputs below contain private signing material.
for NAME in BUILD_CERTIFICATE_BASE64 P12_PASSWORD PROVISIONING_PROFILE_BASE64 ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY APP_VERSION; do
  if [[ -z "${!NAME}" ]]; then echo "Missing signing input: $NAME" >&2; exit 1; fi
done
TEMP_DIR=$(mktemp -d "$RUNNER_TEMP/opencode-signing.XXXXXX")
KEYCHAIN="$TEMP_DIR/signing.keychain-db"
PROFILE_PATH=''
cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  if [[ -n "$PROFILE_PATH" ]]; then rm -f "$PROFILE_PATH"; fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
KEYCHAIN_PASSWORD=$(openssl rand -hex 24)
printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 -D > "$TEMP_DIR/cert.p12"
printf '%s' "$PROVISIONING_PROFILE_BASE64" | base64 -D > "$TEMP_DIR/profile.mobileprovision"
printf '%s' "$ASC_PRIVATE_KEY" > "$TEMP_DIR/AuthKey_${ASC_KEY_ID}.p8"
chmod 600 "$TEMP_DIR"/*
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$TEMP_DIR/cert.p12" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
security cms -D -i "$TEMP_DIR/profile.mobileprovision" > "$TEMP_DIR/profile.plist"
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$TEMP_DIR/profile.plist")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print Name' "$TEMP_DIR/profile.plist")
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"
PROFILE_PATH="$PROFILE_DIR/$PROFILE_UUID.mobileprovision"
cp "$TEMP_DIR/profile.mobileprovision" "$PROFILE_PATH"
export PROFILE_NAME TEMP_DIR
python3 - <<'PYTHON'
import os, plistlib
from pathlib import Path
profile = plistlib.loads((Path(os.environ['TEMP_DIR']) / 'profile.plist').read_bytes())
entitlements = profile['Entitlements']
assert entitlements['application-identifier'] == '4C8FWEBR8F.uk.co.laingcorp.opencode-client.OpenCodeRemote'
assert entitlements.get('com.apple.developer.ubiquity-kvstore-identifier'), 'Profile lacks required iCloud key-value entitlement'
options = {'method': 'app-store-connect', 'destination': 'upload', 'teamID': '4C8FWEBR8F', 'signingStyle': 'manual', 'signingCertificate': 'Apple Distribution', 'manageAppVersionAndBuildNumber': False, 'provisioningProfiles': {'uk.co.laingcorp.opencode-client.OpenCodeRemote': os.environ['PROFILE_NAME']}}
(Path(os.environ['TEMP_DIR']) / 'ExportOptions.plist').write_bytes(plistlib.dumps(options))
PYTHON
xcodebuild archive -project OpenCodeRemote/OpenCodeRemote.xcodeproj -scheme OpenCodeRemote -configuration Release -destination 'generic/platform=iOS' -archivePath "$TEMP_DIR/OpenCodeRemote.xcarchive" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Distribution' PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$APP_VERSION"
python3 scripts/ci/release_guard.py verify-tag
xcodebuild -exportArchive -archivePath "$TEMP_DIR/OpenCodeRemote.xcarchive" -exportOptionsPlist "$TEMP_DIR/ExportOptions.plist" -exportPath "$TEMP_DIR/export" -authenticationKeyPath "$TEMP_DIR/AuthKey_${ASC_KEY_ID}.p8" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -allowProvisioningUpdates
