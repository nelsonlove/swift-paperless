import os

extension Logger {
  static let common = Logger(subsystem: AppIdentity.bundleIDPrefix, category: "Common")
  static let cache = Logger(subsystem: AppIdentity.bundleIDPrefix, category: "Cache")
}
