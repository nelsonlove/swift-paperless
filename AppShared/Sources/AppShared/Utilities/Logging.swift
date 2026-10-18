//
//  Logging.swift
//  swift-paperless
//
//  Created by Paul Gessinger on 03.05.23.
//

import Common
import Foundation
import os

extension Logger {
  private static let subsystem = AppIdentity.bundleIDPrefix

  public static let shared = Logger(subsystem: subsystem, category: "General")
  public static let api = Logger(subsystem: subsystem, category: "API")
  /// Offline sync/fill/reconcile — the active server (DocumentStore /
  /// CachingRepository) and every inactive server (SyncEngine). Filter with
  /// `log stream --predicate 'category == "Sync"'` to watch the whole
  /// multi-server sync in isolation.
  public static let sync = Logger(subsystem: subsystem, category: "Sync")
  public static let fileProvider = Logger(subsystem: subsystem, category: "FileProvider")
  public static let migration = Logger(
    subsystem: subsystem, category: "Migration")
  public static let biometric = Logger(
    subsystem: subsystem, category: "Biometric")
}
