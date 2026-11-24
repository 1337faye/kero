#!/usr/bin/env bash
# Builds Kero for iOS, unsigned, and packages it as build/Kero-unsigned.ipa
# for sideloading (AltStore, SideStore, Sideloadly, TrollStore, …), which
# sign it with your own identity.
#
#   ios/build-ipa.sh            # from anywhere
#   CONFIGURATION=Debug ios/build-ipa.sh
set -euo pipefail

cd "$(dirname "$0")"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="$PWD/build"
DERIVED="$BUILD_DIR/DerivedData"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is needed: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --quiet

rm -rf "$BUILD_DIR/Payload" "$BUILD_DIR/Kero-unsigned.ipa"
mkdir -p "$BUILD_DIR"

# SwiftTerm ships a build-tool plugin (its build info), which xcodebuild
# runs only when told to trust it.
xcodebuild \
  -project Kero.xcodeproj \
  -scheme Kero \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  build

APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/Kero.app"
if [ ! -d "$APP" ]; then
  echo "no Kero.app at $APP" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
# A stray signature of a build that was signed before would fail to verify.
rm -rf "$BUILD_DIR/Payload/Kero.app/_CodeSignature"
(cd "$BUILD_DIR" && /usr/bin/zip -qry Kero-unsigned.ipa Payload)
rm -rf "$BUILD_DIR/Payload"

echo "$BUILD_DIR/Kero-unsigned.ipa ($(du -h "$BUILD_DIR/Kero-unsigned.ipa" | cut -f1))"
