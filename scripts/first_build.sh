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
# The simulator must be an iPhone (the test assumes the iPhone layout of
# Files) and Files must run in English: the test looks up English labels.
# It passes -AppleLanguages (en) to both apps, which Files may ignore, so set
# the simulator's language to English too.
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

# The test assumes the iPhone layout of Files.
xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["udid"] == udid:
            kind = d.get("deviceTypeIdentifier", "") or d.get("name", "")
            sys.exit(0 if "iPhone" in kind else "error: " + udid + " is not an iPhone (" + kind + ")")
sys.exit("error: no simulator " + udid)
' "$udid"

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
export_attachments() {
  xcrun xcresulttool export attachments --path "$result" --output-path "$out/attachments" \
    || { echo "warning: xcresulttool export failed; skipping the rename" >&2; return 1; }
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
        if os.path.exists(target):
            print(target)
PY
}

if [[ -d "$result" ]]; then
  export_attachments || echo "warning: attachments not exported; the result bundle is at $result" >&2
fi

exit "$status"
