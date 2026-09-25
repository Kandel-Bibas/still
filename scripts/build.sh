#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
STILL_SDK_VERSION="$(xcrun --show-sdk-version)"
# SwiftPM's linker can otherwise record the deployment target as the SDK version,
# which makes AppKit and SwiftUI use their older compatibility appearance.
swift build --configuration release \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.2 -Xlinker "$STILL_SDK_VERSION"
STILL_BIN_DIR="$(swift build --configuration release --show-bin-path)"
STILL_APP="${PWD}/dist/Still.app"
mkdir -p "$STILL_APP/Contents/MacOS" "$STILL_APP/Contents/Resources"
cp "$STILL_BIN_DIR/Still" "$STILL_APP/Contents/MacOS/Still"
cp Resources/Info.plist "$STILL_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DTSDKName string macosx${STILL_SDK_VERSION}" "$STILL_APP/Contents/Info.plist"
swift scripts/icon.swift "$STILL_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${STILL_SIGN_IDENTITY:--}" --identifier com.bibaskandel.Still "$STILL_APP"
codesign --verify --strict "$STILL_APP"
xcrun vtool -show-build "$STILL_APP/Contents/MacOS/Still" | awk -v expected="$STILL_SDK_VERSION" '
    $1 == "sdk" { found = 1; if ($2 != expected) exit 1 }
    END { if (!found) exit 1 }
'
printf 'Built %s\n' "$STILL_APP"
