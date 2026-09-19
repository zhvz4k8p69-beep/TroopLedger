# TroopLedger macOS updates

The macOS target embeds Sparkle 2.10.0 through Swift Package Manager. The iOS target does not link Sparkle. The app menu has **Check for Updates…**, and **Preferences → Updates** controls Sparkle's daily checks. Automatic installation and system profiling are disabled by default. Settings are stored by Sparkle; the app does not maintain a second copy.

## Update host

`SUFeedURL` in `Configuration/TroopLedger-macOS-Info.plist` points to the shared public feed repo used by all of Dom's Mac apps:

https://github.com/zhvz4k8p69-beep/mac-updates/releases/download/updates/TroopLedger-appcast.xml

The permanent `updates` release there hosts each app's feed asset; signed app archives live in immutable releases tagged `TroopLedger-v<marketing>-<build>`. Enclosures always reference a particular version's release asset, never `latest`. No GitHub credentials are embedded in the app or feed. Never rename or move the feed asset — every installed copy has this URL baked in.

## Signing key

A dedicated Ed25519 key lives in the macOS login Keychain under service `https://sparkle-project.org`, account `com.bettnet.TroopLedger` (Sparkle's `generate_keys --account com.bettnet.TroopLedger`). Only the public key is stored in `SUPublicEDKey`. All release signing must use this same Keychain account; the private key is backed up in 1Password. Losing it means installed copies can never verify another update, so do not regenerate or replace it.

Sparkle's tools live in the build directory at `SourcePackages/artifacts/sparkle/Sparkle/bin/`; the scripts find them automatically.

## Shipping a release

1. Bump `CURRENT_PROJECT_VERSION` in **both** `project.yml` and `TroopLedger.xcodeproj/project.pbxproj` (the checked-in pbxproj is authoritative; XcodeGen regeneration is safe but not automatic). Sparkle compares build numbers, not marketing versions. Commit.
2. Build, sign, notarize, and staple a universal (arm64 + x86_64) Developer ID app:

   ```sh
   ./Scripts/release-mac.sh            # add --install to also replace /Applications/TroopLedger.app
   ```

   The script refuses a build without Hardened Runtime, the sandbox/CloudKit/Sparkle entitlements, both architectures, the permanent feed URL, a 32-byte public key, or with the starting-workbook snapshot inside the bundle. It uses the `TroopLedger` notarytool Keychain profile, falling back to `BettWatch` (same team).
3. Package, sign the appcast entry, and publish:

   ```sh
   ./Scripts/prepare-sparkle-update.sh --publish
   ```

   Without `--publish` it only prepares `dist/sparkle/<tag>/` for review. With it, the script creates the versioned release in `mac-updates`, waits until the zip downloads anonymously, and only then replaces `TroopLedger-appcast.xml` in the `updates` release — the moment installed copies start seeing the update. The new feed is merged with the live one so earlier releases stay listed.
4. Test from an older **signed, installed, Sparkle-enabled** copy: check for updates, verify the version, install, relaunch, and verify the troop records. An unsigned unit-test build does not prove installer or production feed behavior.

Existing copies without Sparkle require one manual upgrade to the first Sparkle-enabled release (1.1 build 26).

## Sandbox and development

The app keeps network client access and enables Sparkle's Installer XPC service with `SUEnableInstallerLauncherService`. The entitlement list grants the two bundle-specific Sparkle Mach service names (`com.bettnet.TroopLedger-spks` / `-spki`). The extra Downloader XPC service is not enabled because the app already has network access. Keep Hardened Runtime and library validation enabled for distribution. Use Apple Development signing to launch local builds with Sparkle; do not disable library validation for release builds.

The updater skips startup inside XCTest and refuses invalid/missing feed or verification-key configuration. Its preferences tab explains a configuration failure instead of contacting a placeholder server.

References: [Sparkle setup](https://sparkle-project.org/documentation/), [SwiftUI setup](https://sparkle-project.org/documentation/programmatic-setup/), [sandboxing](https://sparkle-project.org/documentation/sandboxing/), [publishing](https://sparkle-project.org/documentation/publishing/).
