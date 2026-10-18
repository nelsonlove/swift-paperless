//
//  AppIdentity.swift
//  swift-paperless
//

import Foundation

/// The identity the build gave the app: the bundle id prefix and the app group.
///
/// Both come from `Config/Shared/Identity.xcconfig` (or a developer's
/// `Local.xcconfig`) through two Info.plist keys that the app and every
/// extension carry, so a fork signed under another team needs no source
/// change. A process without those keys (the SwiftPM test runner on the host)
/// gets the upstream values.
public enum AppIdentity {
  /// The upstream values, used when the bundle has no Info.plist key.
  public static let defaultBundleIDPrefix = "com.paulgessinger.swift-paperless"
  public static let defaultAppGroup = "group.com.paulgessinger.swift-paperless"

  /// The main app's bundle id; the extensions' ids add a suffix to it. Also the
  /// subsystem of every `Logger`, so the in-app log view finds the packages'
  /// entries.
  public static let bundleIDPrefix = infoValue("SWPBundleIDPrefix") ?? defaultBundleIDPrefix

  /// The shared app group, as in the `.entitlements` files.
  public static let appGroup = infoValue("SWPAppGroupIdentifier") ?? defaultAppGroup

  /// A non-empty, fully expanded Info.plist string, or `nil`.
  static func infoValue(_ key: String, bundle: Bundle = .main) -> String? {
    guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
      !value.isEmpty, !value.contains("$(")
    else { return nil }
    return value
  }
}
