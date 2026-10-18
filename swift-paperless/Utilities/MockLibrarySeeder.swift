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

      // The list opens with the saved filter; forget it so the app asks for the
      // default list the seed writes.
      FilterModel.clearSavedFilterState()

      do {
        let report = try await MockLibrary.seed(
          database: stack.database,
          contentStore: stack.contentReclaimer.store,
          fileIndex: stack.contentReclaimer,
          archiveURL: { Bundle.main.url(forResource: $0, withExtension: "pdf") })
        Logger.shared.notice(
          "Mock library seeded: \(report.documents, privacy: .public) documents, \(report.storedFiles, privacy: .public) files stored, \(report.keptFiles, privacy: .public) kept, \(report.removedDocuments, privacy: .public) removed, list written \(report.listWritten, privacy: .public), missing \(report.missingFiles, privacy: .public), unindexed \(report.unindexedFiles, privacy: .public)"
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

      // The row as the seed left it, with the settings it kept. Made active
      // without the connection-change event: the launch task's own
      // `refreshConnection` runs next and must be the only one.
      do {
        guard let record = try stack.database.connection(id: MockLibrary.serverID) else {
          Logger.shared.error("The mock library's server row is missing after the seed")
          return
        }
        stack.connectionManager.activateSeededConnection(StoredConnection(record: record))
      } catch {
        Logger.shared.error("Reading the mock library's server row failed: \(error)")
      }
    }
  }

#endif
