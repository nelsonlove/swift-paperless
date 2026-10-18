#if canImport(FileProvider)

  import DataModel
  import Foundation
  import Persistence
  import Testing

  @testable import AppShared

  /// The watch over a harness's database, recording which servers it signals.
  @MainActor
  @Suite
  struct FileProviderLibraryWatchTests {
    private final class Signals {
      var ids: [UUID] = []
    }

    private func watch(
      _ harness: StoreHarness, servers: [UUID]? = nil
    ) -> (FileProviderLibraryWatch, Signals) {
      let signals = Signals()
      let database = harness.database
      let watch = FileProviderLibraryWatch(
        changes: { database.observeLibraryChanges() },
        servers: { servers ?? [harness.serverID] },
        signal: { signals.ids.append($0) })
      watch.start()
      return (watch, signals)
    }

    @Test("A document edit written through signals the server")
    func editSignals() async throws {
      let harness = try await StoreHarness.make(documents: [document(1)])
      let (watch, signals) = watch(harness)
      defer { watch.stop() }
      let repository = try #require(harness.session.repository)

      var edited = document(1)
      edited.title = "Edited"
      _ = try await repository.update(document: edited)

      try await waitUntil({ signals.ids == [harness.serverID] }, "edit never signalled")
    }

    @Test("An element edit written through signals the server")
    func elementEditSignals() async throws {
      let harness = try await StoreHarness.make(tags: [tag(3)])
      let (watch, signals) = watch(harness)
      defer { watch.stop() }
      let repository = try #require(harness.session.repository)

      var renamed = tag(3)
      renamed.name = "house"
      _ = try await repository.update(tag: renamed)

      try await waitUntil({ !signals.ids.isEmpty }, "tag edit never signalled")
    }

    @Test("A reconcile that drops a document signals the server")
    func reconcileSignals() async throws {
      // The transient server has no documents, so the cached one is dropped.
      let harness = try await StoreHarness.make(documents: [document(1)])
      let (watch, signals) = watch(harness)
      defer { watch.stop() }

      await harness.session.reconcileDocuments(force: true)

      try await waitUntil({ !signals.ids.isEmpty }, "reconcile never signalled")
    }

    @Test("A write signals every configured server, since the region does not name one")
    func signalsEveryServer() async throws {
      let harness = try await StoreHarness.make(documents: [document(1)])
      let other = UUID()
      let (watch, signals) = watch(harness, servers: [harness.serverID, other])
      defer { watch.stop() }

      try await harness.database.upsertDocuments([document(2)], serverID: harness.serverID)

      try await waitUntil({ Set(signals.ids) == [harness.serverID, other] }, "not every server")
    }

    @Test("A write outside the library signals nothing")
    func unrelatedWriteIsSilent() async throws {
      let harness = try await StoreHarness.make()
      let (watch, signals) = watch(harness)
      defer { watch.stop() }

      try await harness.database.setLastRefreshedAt(Date(), serverID: harness.serverID)
      try await Task.sleep(for: .milliseconds(300))

      #expect(signals.ids.isEmpty)
    }
  }

#endif
