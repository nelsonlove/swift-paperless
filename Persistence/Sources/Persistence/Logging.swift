import Common
import os

extension Logger {
  static let persistence = Logger(
    subsystem: AppIdentity.bundleIDPrefix, category: "Persistence")
}
