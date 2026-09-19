# TroopLedger macOS updates

The macOS target embeds Sparkle 2.10.0 through Swift Package Manager. The iOS target does not link Sparkle. The app menu has **Check for Updates…**, and **Preferences → Updates** controls Sparkle's daily checks. Automatic installation and system profiling are disabled by default. Settings are stored by Sparkle; the app does not maintain a second copy.

## Update host

`SUFeedURL` in `Configuration/TroopLedger-macOS-Info.plist` points to:

https://github.com/zhvz4k8p69-beep/TroopLedger/releases/download/updates/appcast.xml

The repository is public. Its permanent `updates` release hosts the feed; signed app archives belong in immutable versioned releases. `Updates/appcast.xml` is the initial empty feed, so update checks succeed but offer no download until the first signed release is added. Never overwrite an established feed with this bootstrap copy.

Each appcast enclosure must reference a particular version's release asset, never `latest`. No GitHub credentials are embedded in the app or feed.

## Signing key

A dedicated Ed25519 key was generated in the macOS Keychain under account `com.bettnet.TroopLedger` using Sparkle's `generate_keys`. Only the public key is stored in `SUPublicEDKey`. Future release signing must use this same Keychain account. Securely back up the private key using Sparkle's documented key export procedure to an encrypted location outside this repository. Losing it complicates updating installed copies; do not regenerate or replace it casually.

Sparkle's tools live in the build directory at:

```
SourcePackages/artifacts/sparkle/Sparkle/bin/
```

The SPM version is pinned in `project.yml` and `Package.resolved`. The YAML now records the existing app target marketing version (1.1) and development team so regeneration preserves them.

## Preparing a release

1. Keep the permanent feed URL unchanged. Increase `CURRENT_PROJECT_VERSION` for every update; Sparkle compares build versions, not just marketing versions. The current build number is 25.
2. Archive **TroopLedger-macOS** in Release with both Apple Silicon and Intel architectures. Use Xcode Organizer's Developer ID export/notarization workflow, then staple the notarization ticket. Standard archive/export signing handles Sparkle's nested helpers. Keep CloudKit and existing file-picker entitlements.
3. Pass the exported, notarized `.app` to the preparation script. Use a new output directory and the immutable URL prefix for that version's public release:

```sh
Scripts/prepare-sparkle-update.sh \
  '/path/to/export/TroopLedger.app' \
  '/path/to/new-release-output' \
  'https://github.com/zhvz4k8p69-beep/TroopLedger/releases/download/vVERSION/' \
  '/path/to/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin'
```

The script verifies the app signature, Gatekeeper acceptance, stapled ticket, universal architectures, matching signing key, and embedded Sparkle. It prepares a ZIP, signed appcast, and checksum file locally. It never uploads, notarizes, installs, or publishes anything. Its generated feed contains the prepared version only and no delta updates.

4. Review the generated XML and archive. Upload the ZIP to its immutable versioned release, confirm it downloads without signing into GitHub, then replace the feed asset in the `updates` release:

   ```sh
   gh release upload updates /path/to/new-release-output/appcast.xml \
     --repo zhvz4k8p69-beep/TroopLedger --clobber
   ```

   This upload publishes the update to installed clients. Publish the archive before changing the feed. Do not rename an asset after generating the appcast. If maintaining older OS branches, merge their existing entries using Sparkle's appcast workflow rather than replacing a multi-branch feed with this one-version feed.
5. Test from an older **signed, installed, Sparkle-enabled** copy: check for updates, verify the version/notes, install, relaunch, and verify the app's troop records. Test automatic checks as well. An unsigned unit-test build does not prove installer or production feed behavior.

Existing copies without Sparkle require one manual upgrade to the first Sparkle-enabled release.

## Sandbox and development

The app keeps network client access and enables Sparkle's Installer XPC service with `SUEnableInstallerLauncherService`. The entitlement list grants the two bundle-specific Sparkle Mach service names. The extra Downloader XPC service is not enabled because the app already has network access. Keep Hardened Runtime and library validation enabled for distribution. Use Apple Development signing to launch local builds with Sparkle; do not disable library validation for release builds.

The updater skips startup inside XCTest and refuses invalid/missing feed or verification-key configuration. Its preferences tab explains a configuration failure instead of contacting a placeholder server.

References: [Sparkle setup](https://sparkle-project.org/documentation/), [SwiftUI setup](https://sparkle-project.org/documentation/programmatic-setup/), [sandboxing](https://sparkle-project.org/documentation/sandboxing/), [publishing](https://sparkle-project.org/documentation/publishing/).
