//
//  AppIdentity.swift
//  swift-paperless
//

import Foundation
import os

/// The identity the build gave the app: the bundle id prefix and the app group.
///
/// Both come from `Config/Shared/Identity.xcconfig` (or a developer's
/// `Local.xcconfig`) through two Info.plist keys that the app and every
/// extension carry, so a fork signed under another team needs no source
/// change. A process that is not the app or one of its extensions (a test
/// runner, a SwiftUI preview host) gets the upstream values silently; an app or
/// extension bundle without the keys is a build error, which is logged (and
/// asserted in Debug) before the same fallback.
public enum AppIdentity {
  /// The upstream values. They must equal `Config/Shared/Identity.xcconfig`;
  /// `AppIdentityTests` checks it.
  public static let defaultBundleIDPrefix = "com.paulgessinger.swift-paperless"
  public static let defaultAppGroup = "group.com.paulgessinger.swift-paperless"

  /// The main app's bundle id; the extensions' ids add a suffix to it. Also the
  /// subsystem of every `Logger` in every process (app and extensions), so one
  /// process logs under one subsystem and the in-app log view finds every
  /// entry, on Mac Catalyst too, where the bundle id differs from the prefix.
  public static let bundleIDPrefix = resolve(
    "SWPBundleIDPrefix", default: defaultBundleIDPrefix)

  /// The shared app group, as in the `.entitlements` files.
  public static let appGroup = resolve("SWPAppGroupIdentifier", default: defaultAppGroup)

  /// The Info.plist value for `key`, or `fallback`. An app or extension bundle
  /// without a usable value calls `onMissing` first.
  static func resolve(
    _ key: String, default fallback: String, bundle: Bundle = .main,
    onMissing: (String) -> Void = reportMissing
  ) -> String {
    if let value = infoValue(key, bundle: bundle) { return value }
    if isAppOrExtension(bundleURL: bundle.bundleURL, bundleIdentifier: bundle.bundleIdentifier) {
      onMissing(key)
    }
    return fallback
  }

  /// Whether a bundle is the app or one of its extensions, which must carry the
  /// keys: an `.app` or `.appex` that is not one of Apple's hosts (such as the
  /// SwiftUI preview agent). Test runners (`xctest`, `swiftpm-testing-helper`)
  /// and other tools are not.
  static func isAppOrExtension(bundleURL: URL, bundleIdentifier: String?) -> Bool {
    guard ["app", "appex"].contains(bundleURL.pathExtension) else { return false }
    return !(bundleIdentifier ?? "").hasPrefix("com.apple.")
  }

  /// Logs a missing or unexpanded key and stops a Debug build. Its own logger:
  /// the shared ones take their subsystem from this type.
  static func reportMissing(_ key: String) {
    Logger(subsystem: defaultBundleIDPrefix, category: "AppIdentity").error(
      "Info.plist key \(key, privacy: .public) is missing or unexpanded; using the upstream value")
    assertionFailure("Info.plist key \(key) is missing or unexpanded")
  }

  /// A non-empty, fully expanded Info.plist string, or `nil`.
  static func infoValue(_ key: String, bundle: Bundle = .main) -> String? {
    guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
      !value.isEmpty, !value.contains("$("), !value.contains("${")
    else { return nil }
    return value
  }
}
