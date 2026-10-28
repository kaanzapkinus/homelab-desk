#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="${HOMELAB_DESK_BUILD_DIR:-$ROOT/build}"
APP="$OUT/Homelab Desk.app"
EXT="$APP/Contents/PlugIns/HomelabDeskWidgets.appex"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Bridge" "$EXT/Contents/MacOS"
ARCH="$(uname -m)"
FLAGS=(-swift-version 5 -parse-as-library -target "${ARCH}-apple-macos14.0" -sdk "$SDK" -O)
xcrun swiftc "${FLAGS[@]}" -application-extension \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -rpath -Xlinker @executable_path/../../../../Frameworks \
    "$ROOT/Sources/Shared/Models.swift" \
    "$ROOT/Sources/Shared/HostMetrics.swift" \
    "$ROOT/Sources/Widgets/HomelabWidgets.swift" \
    -framework WidgetKit -framework SwiftUI -framework Network \
    -o "$EXT/Contents/MacOS/HomelabDeskWidgets"
xcrun swiftc "${FLAGS[@]}" "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/App/*.swift -framework SwiftUI -framework AppKit -framework Charts -framework Network -framework ServiceManagement -o "$APP/Contents/MacOS/HomelabDesk"
cp "$ROOT/Resources/App-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Widget-Info.plist" "$EXT/Contents/Info.plist"
if [[ -n "${HOMELAB_STATUS_URL:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :HomelabStatusURL $HOMELAB_STATUS_URL" "$EXT/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :HomelabStatusURL string $HOMELAB_STATUS_URL" "$EXT/Contents/Info.plist"
fi
cp "$ROOT/bridge/recovery.cjs" "$APP/Contents/Resources/Bridge/recovery.cjs"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - --entitlements "$ROOT/Resources/Widget.entitlements" "$EXT"
    codesign --force --sign - "$APP"
else
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements "$ROOT/Resources/Widget.entitlements" "$EXT"
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$APP"
fi
codesign --verify --deep --strict "$APP"
printf 'Built and signed (identity: %s): %s\n' "$SIGNING_IDENTITY" "$APP"
if [[ "${1:-}" == "--install" ]]; then
    DEST="${HOMELAB_DESK_INSTALL_DIR:-$HOME/Applications}/Homelab Desk.app"
    mkdir -p "$(dirname "$DEST")"
    ditto "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    pluginkit -a "$DEST/Contents/PlugIns/HomelabDeskWidgets.appex"
    pluginkit -e use -i com.homelab.desk.widgets 2>/dev/null || true
    printf 'Installed: %s\n' "$DEST"
fi
