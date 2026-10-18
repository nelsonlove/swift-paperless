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
packages_dir="${PACKAGES_DIR:-}"

# Absolute paths, resolved against the caller's working directory, before the
# cd below.
abspath() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac; }
out="$(abspath "$out")"
derived="$(abspath "$derived")"
[[ -n "$packages_dir" ]] && packages_dir="$(abspath "$packages_dir")"

cd "$(dirname "$0")/.."

export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=

packages=()
if [[ -n "$packages_dir" ]]; then
  packages=(-clonedSourcePackagesDirPath "$packages_dir" -disableAutomaticPackageResolution)
fi

mkdir -p "$out"
result="$out/FileProviderSmokeTests.xcresult"
rm -rf "$result" "$out/attachments"

xcodegen generate

xcrun simctl bootstatus "$udid" -b

# Start from a clean install: uninstalling removes the app's File Provider
# domains, so Files enumerates the location afresh instead of showing what an
# earlier build left in its cache.
xcrun simctl uninstall "$udid" com.paulgessinger.swift-paperless || true

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
# screenshots and element tree are what tell why. Best effort: an export
# problem is reported and never replaces the test's exit status.
if [[ -d "$result" ]]; then
  {
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
        base = name.replace("/", "-")
        target = os.path.join(folder, base)
        stem, ext = os.path.splitext(base)
        n = 1
        while os.path.exists(target) and target != source:
            n += 1
            target = os.path.join(folder, f"{stem}-{n}{ext}")
        if os.path.exists(source) and source != target:
            os.rename(source, target)
        print(target)
PY
  } || echo "warning: exporting the attachments failed; the result bundle is at $result" >&2
fi

exit "$status"
