#!/usr/bin/env bash
#
# The File Provider's first build, headless: generate the project, build the
# app for a simulator, run the Files-app smoke test
# (swift-paperlessUITests/FileProviderSmokeTests) on it, and export the test's
# screenshots and element trees from the result bundle.
#
# Usage:
#   scripts/first_build.sh <simulator-udid> [output-dir]
#     simulator-udid  a device from `xcrun simctl list devices available`
#     output-dir      where the result bundle and the attachments go
#                     (default: build/first-build)
#
# Environment:
#   DERIVED_DATA      derived data folder (default: build/DerivedData)
#   PACKAGES_DIR      cloned package folder; when set, package resolution is
#                     not run again (-disableAutomaticPackageResolution)
#
# Signs ad hoc (no team, no certificate) and keeps git and Xcode source
# control away from the keychain, as docs/development/local-build.md does.
# Prints the path of every exported attachment.

set -euo pipefail

udid="${1:?usage: scripts/first_build.sh <simulator-udid> [output-dir]}"
out="${2:-build/first-build}"
derived="${DERIVED_DATA:-build/DerivedData}"

cd "$(dirname "$0")/.."

export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=

packages=()
if [[ -n "${PACKAGES_DIR:-}" ]]; then
  packages=(-clonedSourcePackagesDirPath "$PACKAGES_DIR" -disableAutomaticPackageResolution)
fi

mkdir -p "$out"
result="$out/FileProviderSmokeTests.xcresult"
rm -rf "$result" "$out/attachments"

xcodegen generate

xcrun simctl bootstatus "$udid" -b

xcodebuild test \
  -project swift-paperless.xcodeproj \
  -scheme swift-paperlessUITests \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -only-testing:swift-paperlessUITests/FileProviderSmokeTests \
  -scmProvider system \
  ${packages[@]+"${packages[@]}"} \
  -derivedDataPath "$derived" \
  -resultBundlePath "$result" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  && status=0 || status=$?

# Export the attachments whether the test passed or failed: a failure's
# screenshots and element tree are what tell why.
if [[ -d "$result" ]]; then
  xcrun xcresulttool export attachments --path "$result" --output-path "$out/attachments"
  # The exported files are named by UUID; give them the names the test chose
  # (manifest.json's suggestedHumanReadableName) and print their paths.
  python3 - "$out/attachments" <<'PY'
import json, os, sys
folder = sys.argv[1]
with open(os.path.join(folder, "manifest.json")) as f:
    manifest = json.load(f)
for test in manifest:
    for attachment in test.get("attachments", []):
        source = os.path.join(folder, attachment["exportedFileName"])
        name = attachment.get("suggestedHumanReadableName") or attachment["exportedFileName"]
        target = os.path.join(folder, name.replace("/", "-"))
        if os.path.exists(source) and source != target:
            os.rename(source, target)
        print(os.path.abspath(target))
PY
fi

exit "$status"
