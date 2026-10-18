//
//  MockLibrarySeeder.swift
//  swift-paperless
//
//  Debug builds only: `--seed-mock-library` writes the made-up library in
//  `MockLibrary` into the app-group database and content store, and makes it
//  the active server, so the app and the File Provider extension show a
//  library with no Paperless server.
//

#if DEBUG

  import AppShared
  import Foundation
  import os

  @MainActor
  enum MockLibrarySeeder {
    /// Seed when the launch arguments ask for it; a no-op otherwise.
    static func seedIfRequested(stack: AppStack) async {
      guard MockLibrary.isRequested() else { return }
      Logger.shared.notice("Seeding the mock library (\(MockLibrary.launchArgument, privacy: .public))")

      do {
        let report = try await MockLibrary.seed(
          database: stack.database,
          contentStore: stack.contentReclaimer.store,
          fileIndex: stack.contentReclaimer,
          archiveURL: { Bundle.main.url(forResource: $0, withExtension: "pdf") })
        Logger.shared.notice(
          "Mock library seeded: \(report.documents, privacy: .public) documents, \(report.storedFiles, privacy: .public) files stored, \(report.keptFiles, privacy: .public) kept, \(report.removedDocuments, privacy: .public) removed, missing \(report.missingFiles, privacy: .public)"
        )
      } catch {
        Logger.shared.error("Seeding the mock library failed: \(error)")
        return
      }

      // The token is not needed to list the library; a keychain that refuses
      // it (no team, no keychain group) must not stop the seed.
      do {
        try MockLibrary.connection.setToken(MockLibrary.token)
      } catch {
        Logger.shared.warning("Storing the mock library's token failed, continuing: \(error)")
      }

      // Not through `login`: its connection-change event would start a second
      // `refreshConnection` beside the one the launch task runs next. Wait for
      // the manager's observer to hold the row, then point at it, so the
      // pointer never names a server the manager does not have.
      let manager = stack.connectionManager
      let deadline = ContinuousClock.now + .seconds(3)
      while manager.connections[MockLibrary.serverID] == nil, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
      }
      guard manager.connections[MockLibrary.serverID] != nil else {
        Logger.shared.error("The connection manager never saw the mock library's server row")
        return
      }
      manager.activeConnectionId = MockLibrary.serverID
    }
  }

#endif
