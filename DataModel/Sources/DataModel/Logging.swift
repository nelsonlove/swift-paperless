import Common
import os

extension Logger {
  static let dataModel = Logger(
    subsystem: AppIdentity.bundleIDPrefix, category: "DataModel")
}
