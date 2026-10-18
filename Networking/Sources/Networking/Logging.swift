import Common
import os

extension Logger {
  static let networking = Logger(
    subsystem: AppIdentity.bundleIDPrefix, category: "Networking")
}
