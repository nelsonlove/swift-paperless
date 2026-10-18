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

```sh
xcodegen generate
xcodebuild build \
  -project swift-paperless.xcodeproj \
  -scheme swift-paperless \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
```

`CODE_SIGN_IDENTITY=-` signs ad hoc. It needs no certificate. For a simulator build the linker still embeds the entitlements (the app group, and the keychain group with the placeholder prefix `FAKETEAMID`) in the binary's `__TEXT,__entitlements` section, not in the code signature, so `codesign -d --entitlements` shows an empty list. Read the section instead: `otool -X -s __TEXT __entitlements build/DerivedData/Build/Products/Debug-iphonesimulator/Paperless.app/Paperless` prints it as hex.

## Headless package resolution

On a build machine where nobody can answer a keychain prompt, resolve the packages with the git command line and no credential helper. Every dependency is public, so no credentials are needed:

```sh
GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
  xcodebuild -resolvePackageDependencies -project swift-paperless.xcodeproj -scmProvider system
```

The empty `credential.helper` value clears the helper list for that one process only. Pass the same environment and `-scmProvider system` to the build.

## Install and run

```sh
xcrun simctl boot 'iPhone 17 Pro'
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/Paperless.app
xcrun simctl launch booted com.paulgessinger.swift-paperless
xcrun simctl io booted screenshot screenshot.png
```
