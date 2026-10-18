# Building and testing locally

CI builds with the Xcode version in `.xcode-version`. This page is for a Mac with an older Xcode (26.x) and no Apple developer team signed in: it builds the app for the iOS Simulator and runs the package tests, without signing certificates and without any keychain access.

## What you need

- Xcode 26.x with its iOS platform installed. Xcode offers no iOS or simulator destination until it is (the error is "iOS 26.5 is not installed"). Install it in Xcode > Settings > Components, or with `xcodebuild -downloadPlatform iOS`.
- XcodeGen (`brew install xcodegen`).

The `UIHingeInteraction` code in `swift-paperless/Utilities/HingeDetector.swift` needs the iOS 27.1 SDK. `Config/App/App.xcconfig` turns it off for the 27.0 and 26.x SDKs, so nothing else needs changing.

## Package tests (macOS)

The host-testable packages run natively with `swift test`:

```sh
for p in Common DataModel Networking Persistence AppShared; do
  swift test --package-path "$p" --disable-keychain
done
```

`just test` runs the same five, with the same flag. `--disable-keychain` stops SwiftPM from looking up credentials in the login keychain.

## Simulator build without a team

The commands below keep git and Xcode source control away from the login keychain, so they also run on a build machine where nobody can answer a prompt. Every dependency is public, so no credentials are needed. Run them in a subshell, so the environment does not reach later git commands in your terminal:

```sh
(
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
xcodegen generate
xcodebuild -resolvePackageDependencies \
  -project swift-paperless.xcodeproj \
  -scheme swift-paperless \
  -scmProvider system \
  -derivedDataPath build/DerivedData
xcodebuild build \
  -project swift-paperless.xcodeproj \
  -scheme swift-paperless \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -scmProvider system \
  -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
)
```

The empty `credential.helper` value clears git's credential helpers inside the subshell (it replaces any `GIT_CONFIG_COUNT` entries you had there), and `-scmProvider system` makes Xcode fetch packages with that git instead of its own source control, which reads the keychain. Both commands use the same `-derivedDataPath`, so the build finds the packages the first command resolved. Change the device name and `OS` to a simulator you have (`xcrun simctl list devices available`).

`CODE_SIGN_IDENTITY=-` signs ad hoc. It needs no certificate. For a simulator build the linker still embeds the entitlements (the app group, and the keychain group with the placeholder prefix `FAKETEAMID`) in the binary's `__TEXT,__entitlements` section, not in the code signature, so `codesign -d --entitlements` shows an empty list. Read the section instead: `otool -X -s __TEXT __entitlements build/DerivedData/Build/Products/Debug-iphonesimulator/Paperless.app/Paperless` prints it as hex.

## Install and run

Use the simulator's UDID from `xcrun simctl list devices available`, so the command cannot pick a device of another runtime. `bootstatus -b` boots the device if it is not booted and waits until it is ready; it does not fail when the device already runs.

```sh
UDID=<udid of the simulator>
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" build/DerivedData/Build/Products/Debug-iphonesimulator/Paperless.app
APP_ID="$(xcodebuild -showBuildSettings -project swift-paperless.xcodeproj -target swift-paperless -configuration Debug -sdk iphonesimulator 2>/dev/null | awk -F' = ' '/^ +PRODUCT_BUNDLE_IDENTIFIER = / { print $2; exit }')"
xcrun simctl launch "$UDID" "$APP_ID"
xcrun simctl io "$UDID" screenshot build/screenshot.png
```

`build/` is ignored by git, so the screenshot stays out of commits.

`APP_ID` is the app's bundle id from the build settings: `com.paulgessinger.swift-paperless` by default, or your own prefix (next section).

## Building on your own device

The app's identity is build settings, not source: `Config/Shared/Identity.xcconfig` sets the bundle id prefix (`SWP_BUNDLE_ID_PREFIX`), the app group (`SWP_APP_GROUP`) and the keychain group (`SWP_KEYCHAIN_GROUP`, which is `$(AppIdentifierPrefix)$(SWP_BUNDLE_ID_PREFIX)`). The app is `<prefix>`, the extensions are `<prefix>.ShareExtension` and `<prefix>.FileProviderExtension`, and the entitlements and the Info.plist files take the group from the same settings. The Swift code reads the prefix and the group at run time from the Info.plist keys `SWPBundleIDPrefix` and `SWPAppGroupIdentifier` (see `Common/Sources/Common/AppIdentity.swift`), so no other Swift code names them. The only Swift literals of the upstream values are the fallbacks in `AppIdentity` (used when a process has no bundle id, as in the host package tests; a test checks they equal `Identity.xcconfig`) and two logger subsystems in `FileProviderExtension/` that are still to change.

To sign a build for your own iPhone or iPad under your own Apple team:

1. Copy `Config/Shared/Local.xcconfig.example` to `Config/Shared/Local.xcconfig`. Git ignores that file. `Base.xcconfig` includes it last, so it overrides project-level settings only: those in `Base.xcconfig` and `Identity.xcconfig`. A key that a target xcconfig sets (`Config/App/`, `Config/ShareExtension/`, `Config/FileProviderExtension/`) still wins over it, so set only the keys it is meant for: `DEVELOPMENT_TEAM`, `SWP_BUNDLE_ID_PREFIX`, `SWP_APP_GROUP` and, rarely, `SWP_KEYCHAIN_GROUP` (derived from the team prefix and the bundle id prefix by default).
2. In it, set `DEVELOPMENT_TEAM` to your team id, `SWP_BUNDLE_ID_PREFIX` to a bundle id prefix you own (for example `com.example.swift-paperless`), and `SWP_APP_GROUP` to an app group id (for example `group.com.example.swift-paperless`).
3. At developer.apple.com > Certificates, Identifiers & Profiles, register the app group, then three explicit App IDs: `<prefix>`, `<prefix>.ShareExtension` and `<prefix>.FileProviderExtension`. Turn on App Groups for all three and assign your group. Keychain Sharing needs no App ID capability; the keychain group is derived from your team prefix and bundle id prefix. With a paid team, automatic signing can register the App IDs for you on the first build, but you must still create the app group and assign it. A Mac Catalyst build of the app and the Share Extension uses the derived ids `maccatalyst.<prefix>` and `maccatalyst.<prefix>.ShareExtension` (`DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER`), so under your team register those too, with the same app group.
4. Run `xcodegen generate`, open `swift-paperless.xcodeproj`, choose your device and build the `swift-paperless` scheme. Signing is automatic (`SWP_CODE_SIGN_STYLE = Automatic` in `Base.xcconfig`), so Xcode makes the development profiles.

To check what a build will use, run `xcodebuild -showBuildSettings -project swift-paperless.xcodeproj -target FileProviderExtension | grep -E 'PRODUCT_BUNDLE_IDENTIFIER|SWP_'`.

Some things stay upstream's on purpose. The release tooling (`fastlane/`, `scripts/beta_ci.sh`, `scripts/ExportOptions.plist`, `scripts/next_build_number.sh`) signs and uploads upstream's App Store app only, and `scripts/CIArchiveSigning.xcconfig` includes `Identity.xcconfig` (but not `Local.xcconfig`) and is passed with `-xcconfig`, so an archive always has upstream's team and identity. The screenshot tooling (`screenshots.toml`, `swpngx capture`) also keeps upstream's bundle id, like fastlane. `scripts/first_build.sh` and `user-defaults.py` follow your identity: the first reads the bundle id from the build settings, the second takes the group as an argument or from `SWP_APP_GROUP`. The URL scheme `x-paperless` is the same in every build, so with two builds on one device iOS picks one of them for those links.
