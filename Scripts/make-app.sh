#!/bin/bash
# Builds build/SnapShelf.app and signs it with a stable identity, so the
# Screen Recording permission survives rebuilds.
#
#   SIGN_IDENTITY  name or SHA-1 of the signing identity (default: first valid
#                  "Apple Development" identity, then any valid identity)
#   BUNDLE_ID      bundle identifier (default: app.snapshelf.SnapShelf)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SnapShelf"
BUNDLE_ID="${BUNDLE_ID:-app.snapshelf.SnapShelf}"
APP="build/${APP_NAME}.app"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    identities="$(security find-identity -v -p codesigning | grep -v CSSMERR | grep '^ *[0-9])' || true)"
    SIGN_IDENTITY="$(echo "$identities" | grep 'Apple Development' | head -1 | awk '{print $2}')"
    if [[ -z "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="$(echo "$identities" | head -1 | awk '{print $2}')"
    fi
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "error: no code signing identity found." >&2
    echo "Create one (Xcode > Settings > Accounts, or a self-signed 'Code Signing'" >&2
    echo "certificate in Keychain Access) and re-run, or set SIGN_IDENTITY." >&2
    echo "Ad-hoc signing is refused on purpose: it resets Screen Recording access on every build." >&2
    exit 1
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
sed "s/__BUNDLE_ID__/${BUNDLE_ID}/" Support/Info.plist > "$APP/Contents/Info.plist"
if [[ -f Support/AppIcon.icns ]]; then
    cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

codesign --force --options runtime --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with $SIGN_IDENTITY)"
