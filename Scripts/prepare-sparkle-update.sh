#!/bin/bash
#
# prepare-sparkle-update.sh — turn the notarized app from release-mac.sh into a
# Sparkle update: a zipped archive, an Ed25519-signed appcast entry, and a
# checksum. Nothing leaves this Mac unless you pass --publish.
#
# Usage:
#   ./Scripts/prepare-sparkle-update.sh                 # prepare only, review the output
#   ./Scripts/prepare-sparkle-update.sh --publish       # ...then publish to GitHub
#   ./Scripts/prepare-sparkle-update.sh --app /path/to/TroopLedger.app --out /path/to/dir
#
# --publish creates the immutable versioned release in the public mac-updates
# repo with the zip, confirms it downloads anonymously, and only then replaces
# the feed asset in the permanent `updates` release — the moment installed
# copies start seeing the update. Bump CURRENT_PROJECT_VERSION (project.yml and
# project.pbxproj) first: Sparkle compares build numbers (CFBundleVersion), not
# marketing versions.
#
set -euo pipefail

APP_NAME="TroopLedger"                # tag/asset/zip prefix
DISPLAY_NAME="TroopLedger"            # the .app and executable name
BUNDLE_ID="com.bettnet.TroopLedger"   # also the Keychain account of the signing key
UPDATES_REPO="zhvz4k8p69-beep/mac-updates"
FEED_ASSET="$APP_NAME-appcast.xml"
FEED_URL="https://github.com/$UPDATES_REPO/releases/download/updates/$FEED_ASSET"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/build/release-mac/export/$DISPLAY_NAME.app"
OUT=""
PUBLISH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { echo "$*" >&2; exit 1; }
plist="$APP/Contents/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }

# Sparkle's command-line tools ship inside the SwiftPM artifact; find the copy
# that matches the pinned version wherever Xcode resolved it.
find_sparkle_bin() {
  local candidate
  for candidate in "$REPO"/build/*/SourcePackages/artifacts/sparkle/Sparkle/bin \
                   "$HOME"/Library/Developer/Xcode/DerivedData/TroopLedger-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
                   "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    [[ -x "$candidate/generate_appcast" ]] && { echo "$candidate"; return; }
  done
  die "Sparkle tools not found. Build the app once so SwiftPM fetches the Sparkle artifact."
}
SPARKLE_BIN="$(find_sparkle_bin)"

say "Checking $APP"
[[ -f "$plist" ]] || die "No app at $APP — run ./Scripts/release-mac.sh first, or pass --app."
[[ "$(read_plist CFBundleIdentifier)" == "$BUNDLE_ID" ]] || die "Wrong application."
marketing="$(read_plist CFBundleShortVersionString)"
build="$(read_plist CFBundleVersion)"
[[ "$build" =~ ^[0-9]+([.][0-9]+)*$ ]] || die "Build version must be numeric, got '$build'."
[[ "$(read_plist SUFeedURL)" == "$FEED_URL" ]] || die "The app's SUFeedURL is not the permanent feed: $(read_plist SUFeedURL)"
key="$("$SPARKLE_BIN/generate_keys" --account "$BUNDLE_ID" -p)"
[[ "$(read_plist SUPublicEDKey)" == "$key" ]] || die "This app and the Keychain use different update-signing keys."
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || die "Sparkle framework missing from the app."
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/sbin/spctl --assess --type execute "$APP"
/usr/bin/xcrun stapler validate "$APP" >/dev/null
# Universal: the troop's Macs are a mix of Apple silicon and Intel. lipo -archs is
# the only form that behaves under Xcode 26.
archs="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$DISPLAY_NAME")"
for slice in arm64 x86_64; do
  grep -qw "$slice" <<<"$archs" || die "The app is missing the $slice slice (got: $archs)."
done
echo "signed, notarized, stapled, universal — $APP_NAME $marketing ($build)"

tag="$APP_NAME-v$marketing-$build"
download_prefix="https://github.com/$UPDATES_REPO/releases/download/$tag/"
[[ -n "$OUT" ]] || OUT="$REPO/dist/sparkle/$tag"
[[ ! -e "$OUT" ]] || die "$OUT already exists — every build gets a new output directory."
mkdir -p "$OUT"

say "Packaging $tag"
archive="$APP_NAME-$marketing-$build.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$archive"

# Start from the live feed so earlier releases stay listed (generate_appcast
# keeps existing items it has no archive for). A brand-new feed is fine too.
# Sparkle 2.10 names the feed after the archives ("TroopLedger-appcast.xml") and only
# merges into a file of that name: a downloaded "appcast.xml" was ignored, and moving it
# over the generated feed afterwards threw the new build away.
say "Signing and generating the appcast"
if curl -fsSL -o "$OUT/$FEED_ASSET" "$FEED_URL"; then
  echo "merged with the current feed"
else
  rm -f "$OUT/$FEED_ASSET"; echo "no existing feed; starting fresh"
fi
"$SPARKLE_BIN/generate_appcast" --account "$BUNDLE_ID" --maximum-deltas 0 \
  --download-url-prefix "$download_prefix" "$OUT" >/dev/null
# Older Sparkle versions wrote appcast.xml instead; accept that too.
if [[ -f "$OUT/appcast.xml" && ! -f "$OUT/$FEED_ASSET" ]]; then mv "$OUT/appcast.xml" "$OUT/$FEED_ASSET"; fi
[[ -f "$OUT/$FEED_ASSET" ]] || die "generate_appcast wrote no feed in $OUT."
# Sparkle 2.10 writes <sparkle:version>N</sparkle:version>; older feeds used the attribute form.
grep -Eq "sparkle:version(=\"|>)$build(\"|<)" "$OUT/$FEED_ASSET" || die "Generated feed does not contain build $build."
grep -q "$download_prefix$archive" "$OUT/$FEED_ASSET" || die "Generated feed does not point at $download_prefix$archive."
/usr/bin/shasum -a 256 "$OUT/$archive" > "$OUT/SHA256SUMS.txt"
echo "prepared:"
echo "  $OUT/$archive"
echo "  $OUT/$FEED_ASSET"
echo "  $OUT/SHA256SUMS.txt"

if [[ "$PUBLISH" -eq 0 ]]; then
  say "Not published"
  echo "Review the files above, then re-run with --publish (or upload by hand:"
  echo "  gh release create $tag $OUT/$archive --repo $UPDATES_REPO --title \"$APP_NAME $marketing ($build)\""
  echo "  gh release upload updates $OUT/$FEED_ASSET --repo $UPDATES_REPO --clobber )"
  exit 0
fi

say "Publishing $tag to $UPDATES_REPO"
gh release view "$tag" --repo "$UPDATES_REPO" >/dev/null 2>&1 \
  && die "Release $tag already exists. Releases are immutable — bump CURRENT_PROJECT_VERSION and rebuild."
gh release create "$tag" "$OUT/$archive" "$OUT/SHA256SUMS.txt" --repo "$UPDATES_REPO" \
  --title "$DISPLAY_NAME $marketing ($build)" \
  --notes "Signed, notarized macOS build of $DISPLAY_NAME $marketing (build $build). Installed copies update through Sparkle."
# GitHub's CDN can lag a new asset by a minute; do not flip the feed until the
# archive is actually reachable without credentials.
say "Waiting for the archive to be downloadable anonymously"
for attempt in $(seq 1 30); do
  code="$(curl -sSL -o /dev/null -w '%{http_code}' "$download_prefix$archive" || true)"
  [[ "$code" == "200" ]] && break
  sleep 5
done
[[ "$code" == "200" ]] || die "Archive not reachable at $download_prefix$archive (HTTP $code). Feed NOT updated."

say "Publishing the feed"
gh release upload updates "$OUT/$FEED_ASSET" --repo "$UPDATES_REPO" --clobber
echo "done — installed copies will offer $marketing ($build) on their next check."
echo "Verify from an older installed copy: TroopLedger menu → Check for Updates…"
