#!/bin/bash
# Prepare local, signed Sparkle update files from an already exported/notarized app.
# Does not upload, publish, notarize, or install anything.
set -euo pipefail
if [[ $# -ne 4 ]]; then
    echo "Usage: $0 /path/TroopLedger.app /path/new-output-dir https://host/download/path/ /path/Sparkle/bin" >&2
    exit 2
fi
app="$1"
output="$2"
download_prefix="$3"
sparkle_bin="$4"
plist="$app/Contents/Info.plist"
[[ -f "$plist" && -x "$sparkle_bin/generate_appcast" ]] || { echo "App or Sparkle tools missing." >&2; exit 1; }
[[ "$download_prefix" == https://*/ ]] || { echo "Download URL must use HTTPS and end with /." >&2; exit 1; }
[[ ! -e "$output" ]] || { echo "Use a new output directory to avoid overwriting an existing release." >&2; exit 1; }
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
[[ "$(read_plist CFBundleIdentifier)" == com.bettnet.TroopLedger ]] || { echo "Wrong application." >&2; exit 1; }
version="$(read_plist CFBundleVersion)"
[[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || { echo "Build version must be numeric." >&2; exit 1; }
key="$("$sparkle_bin/generate_keys" --account com.bettnet.TroopLedger -p)"
[[ "$(read_plist SUPublicEDKey)" == "$key" ]] || { echo "This app and Keychain use different update-signing keys." >&2; exit 1; }
[[ "$(read_plist SUFeedURL)" == https://* ]] || { echo "The app needs its permanent HTTPS feed URL." >&2; exit 1; }
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || { echo "Sparkle framework missing from app." >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app"
/usr/sbin/spctl --assess --type execute "$app"
/usr/bin/xcrun stapler validate "$app"
# Fail rather than distribute an Intel-incompatible update inadvertently.
# `-archs` rather than `-verify_arch`: the latter rejects its input ("requires
# exactly one input file") under Xcode 26 in either argument order.
archs="$(/usr/bin/lipo -archs "$app/Contents/MacOS/TroopLedger")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "The app is not universal (arm64 + x86_64): $archs" >&2; exit 1; }
mkdir -p "$output"
archive="TroopLedger-$version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
# The output path is explicit: left to its default, Sparkle 2.10 names the feed
# after the app (TroopLedger-appcast.xml), not the appcast.xml the release guide
# and the `updates` release expect.
"$sparkle_bin/generate_appcast" --account com.bettnet.TroopLedger --maximum-deltas 0 \
    --download-url-prefix "$download_prefix" -o "$output/appcast.xml" "$output"
# Sparkle 2 writes <sparkle:version>N</sparkle:version>; older feeds used an attribute.
grep -Eq "sparkle:version(=\"$version\"|>$version<)" "$output/appcast.xml" \
    || { echo "Generated feed does not contain build $version." >&2; exit 1; }
grep -q "$download_prefix$archive" "$output/appcast.xml" \
    || { echo "Generated feed does not point at $download_prefix$archive." >&2; exit 1; }
/usr/bin/shasum -a 256 "$output/$archive" > "$output/SHA256SUMS.txt"
echo "Prepared $output/$archive and $output/appcast.xml. Review these files before publishing."
