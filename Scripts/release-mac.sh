#!/bin/bash
#
# release-mac.sh — build a notarized, standalone TroopLedger.app.
#
# Archive → export (Developer ID) → zip → notarize → staple → verify, then
# optionally install to /Applications. Same shape as BettWatch/ReadyRoom/
# BettMoney's release-mac.sh so the four apps ship the same way.
#
# ONE-TIME SETUP (stores an Apple ID + app-specific password in the keychain so
# this script never sees a secret). Any profile for team YYNDN9V2A4 works; the
# script uses "TroopLedger" and falls back to "BettWatch" if that is the one
# that exists:
#
#   xcrun notarytool store-credentials "TroopLedger" \
#       --apple-id "you@example.com" \
#       --team-id YYNDN9V2A4 \
#       --password "xxxx-xxxx-xxxx-xxxx"     # app-specific password
#
# Usage:
#   ./Scripts/release-mac.sh              # build + notarize + staple
#   ./Scripts/release-mac.sh --install    # ...and copy to /Applications
#   ./Scripts/release-mac.sh --no-notarize   # build + sign only (offline)
#
set -euo pipefail

TEAM_ID="YYNDN9V2A4"
APP_NAME="TroopLedger"
SCHEME="TroopLedger-macOS"
FEED_URL="https://github.com/zhvz4k8p69-beep/mac-updates/releases/download/updates/TroopLedger-appcast.xml"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/build/release-mac"
DIST="$REPO/dist"
ARCHIVE="$BUILD/$SCHEME.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/$APP_NAME.app"
ZIP="$DIST/$APP_NAME.zip"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

INSTALL=0
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

if [ "$NOTARIZE" -eq 1 ]; then
  KEYCHAIN_PROFILE="${NOTARY_PROFILE:-}"
  if [ -z "$KEYCHAIN_PROFILE" ]; then
    for candidate in TroopLedger BettWatch; do
      if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then KEYCHAIN_PROFILE="$candidate"; break; fi
    done
  fi
  [ -n "$KEYCHAIN_PROFILE" ] || { echo "No notarytool keychain profile found; see the one-time setup at the top of this script." >&2; exit 1; }
fi

# The checked-in project.pbxproj is authoritative (Xcode has touched it since the
# last `xcodegen generate`); regenerate by hand only when project.yml changes.
say "Archiving (Release, Hardened Runtime, universal)"
cd "$REPO"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$BUILD" "$DIST"
xcodebuild -project TroopLedger.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  ONLY_ACTIVE_ARCH=NO \
  -allowProvisioningUpdates archive >/dev/null

say "Exporting with Developer ID"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" -exportPath "$EXPORT" \
  -allowProvisioningUpdates >/dev/null

say "Checking the signature before submitting"
codesign --verify --strict --deep "$APP"
# Capture first, then match: piping codesign into `grep -q` races SIGPIPE under
# pipefail and rejects correctly signed apps (see BettWatch's release-mac.sh).
SIGINFO=$(codesign -d --verbose=2 "$APP" 2>&1 || true)
grep -q "flags=0x10000(runtime)" <<<"$SIGINFO" \
  || { echo "Hardened Runtime is NOT enabled — notarization would fail." >&2; exit 1; }
# A build missing any of these silently breaks CloudKit sync, file import/export,
# or Sparkle's sandboxed installer.
ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null)
for required in com.apple.security.app-sandbox \
                com.apple.security.files.user-selected.read-write \
                com.apple.security.network.client \
                com.apple.developer.icloud-services \
                iCloud.com.bettnet.TroopLedger \
                com.apple.security.temporary-exception.mach-lookup.global-name \
                com.bettnet.TroopLedger-spks com.bettnet.TroopLedger-spki; do
  grep -q "$required" <<<"$ENTS" || { echo "Missing entitlement: $required" >&2; exit 1; }
done
grep -q "get-task-allow" <<<"$ENTS" && { echo "get-task-allow is set — this is a debug build." >&2; exit 1; }
# Both slices: the troop's Macs are a mix of Apple silicon and Intel. lipo -archs
# is the only form that behaves under Xcode 26.
ARCHS=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$APP_NAME")
for slice in arm64 x86_64; do
  grep -qw "$slice" <<<"$ARCHS" || { echo "Missing $slice slice (got: $ARCHS) — not a universal build." >&2; exit 1; }
done
# Sparkle must be embedded and the build must carry its permanent feed and
# verification key, or installed copies can never update past this one.
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] \
  || { echo "Sparkle.framework is not embedded — updates would not work." >&2; exit 1; }
SUFEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true)
[ "$SUFEED" = "$FEED_URL" ] || { echo "SUFeedURL is not the permanent feed: '$SUFEED'" >&2; exit 1; }
SUKEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
[ "$(printf '%s' "$SUKEY" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" = "32" ] \
  || { echo "SUPublicEDKey is not a 32-byte Ed25519 key: '$SUKEY'" >&2; exit 1; }
# The starting-workbook snapshot holds real names; it must never ship in Release.
[ ! -e "$APP/Contents/Resources/TroopFinanceImport.json" ] \
  || { echo "TroopFinanceImport.json is inside the Release app — EXCLUDED_SOURCE_FILE_NAMES is broken." >&2; exit 1; }
echo "signature, hardened runtime, entitlements, universal, and Sparkle configuration all good"

say "Packaging"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$NOTARIZE" -eq 1 ]; then
  say "Notarizing with profile '$KEYCHAIN_PROFILE' (this waits for Apple; usually a couple of minutes)"
  if ! xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
    echo "Notarization failed. For the details of a specific run:" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile \"$KEYCHAIN_PROFILE\"" >&2
    exit 1
  fi

  say "Stapling the ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"

  say "Gatekeeper verdict"
  spctl -a -vvv -t exec "$APP" 2>&1 | head -3

  # Re-zip so the distributed archive contains the stapled app.
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
fi

if [ "$INSTALL" -eq 1 ]; then
  say "Installing to /Applications"
  pkill -f "/Applications/$APP_NAME.app" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  codesign --verify --strict "/Applications/$APP_NAME.app"
  echo "installed"
fi

say "Done"
echo "app: $APP"
echo "zip: $ZIP"
echo ""
echo "To ship this build to every Mac running TroopLedger (bump CURRENT_PROJECT_VERSION first):"
echo "  ./Scripts/prepare-sparkle-update.sh --publish"
