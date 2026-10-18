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

`just test` runs the same five. `--disable-keychain` stops SwiftPM from looking up credentials in the login keychain.

## Simulator build without a team

The commands below keep git and Xcode source control away from the login keychain, so they also run on a build machine where nobody can answer a prompt. Every dependency is public, so no credentials are needed. Set this environment once in the shell:

```sh
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
```

The empty `credential.helper` value clears git's credential helpers for this shell only, and `-scmProvider system` below makes Xcode fetch packages with that git instead of its own source control (which reads the keychain).

```sh
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
```

Both commands use the same `-derivedDataPath`, so the build finds the packages the first command resolved. Change the device name and `OS` to a simulator you have (`xcrun simctl list devices available`).

`CODE_SIGN_IDENTITY=-` signs ad hoc. It needs no certificate. For a simulator build the linker still embeds the entitlements (the app group, and the keychain group with the placeholder prefix `FAKETEAMID`) in the binary's `__TEXT,__entitlements` section, not in the code signature, so `codesign -d --entitlements` shows an empty list. Read the section instead: `otool -X -s __TEXT __entitlements build/DerivedData/Build/Products/Debug-iphonesimulator/Paperless.app/Paperless` prints it as hex.

## Install and run

Use the simulator's UDID from `xcrun simctl list devices available`, so the command cannot pick a device of another runtime. `bootstatus -b` boots the device if it is not booted and waits until it is ready; it does not fail when the device already runs.

```sh
UDID=<udid of the simulator>
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" build/DerivedData/Build/Products/Debug-iphonesimulator/Paperless.app
xcrun simctl launch "$UDID" com.paulgessinger.swift-paperless
xcrun simctl io "$UDID" screenshot build/screenshot.png
```

`build/` is ignored by git, so the screenshot stays out of commits.
