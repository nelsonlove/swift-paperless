#if canImport(FileProvider)

  import FileProviderCore
  import Foundation
  import Persistence
  import Testing

  @testable import AppShared

  /// Records the domain calls and keeps the domain list they imply.
  private actor FakeDomains: FileProviderDomainManaging {
    var current: [String: String]
    private(set) var calls: [String] = []
    private(set) var listCount = 0
    private let failAdds: Bool

    struct AddFailed: Error {}

    init(_ current: [String: String] = [:], failAdds: Bool = false) {
      self.current = current
      self.failAdds = failAdds
    }

    func domains() async throws -> [DomainReconcile.Domain] {
      listCount += 1
      return current.map { DomainReconcile.Domain(identifier: $0.key, displayName: $0.value) }
    }

    func add(_ domain: DomainReconcile.Domain) async throws {
      calls.append("add \(domain.identifier) \(domain.displayName)")
      if failAdds { throw AddFailed() }
      current[domain.identifier] = domain.displayName
    }

    func remove(_ domain: DomainReconcile.Domain) async throws {
      calls.append("remove \(domain.identifier)")
      current[domain.identifier] = nil
    }
  }

  @MainActor
  @Suite
  struct FileProviderDomainSyncTests {
    private func server(
      _ id: UUID, url: String = "https://paperless.example.com/api/", name: String? = nil
    ) -> StoredConnection {
      StoredConnection(
        id: id, url: URL(string: url)!, extraHeaders: [], user: StoreHarness.user,
        friendlyName: name)
    }

    /// A sync whose observed list and database read are both `servers`, over
    /// a database on disk.
    private func confirmed(
      _ servers: [UUID: StoredConnection], _ domains: FakeDomains
    ) -> FileProviderDomainSync {
      FileProviderDomainSync(
        observed: { servers }, read: { servers }, allowsRemoval: true, manager: domains)
    }

    /// A sync over `model`, read as though from a database on disk unless said
    /// otherwise.
    private func following(
      _ model: ServerList, _ domains: FakeDomains, allowsRemoval: Bool = true
    ) -> FileProviderDomainSync {
      FileProviderDomainSync(
        observed: { model.servers }, read: { model.servers }, allowsRemoval: allowsRemoval,
        manager: domains)
    }

    /// A fresh, empty database file in a new temporary directory.
    private func onDiskDatabase() throws -> Database {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileProviderDomainSyncTests-\(UUID().uuidString)")
      return try Database(path: directory.appendingPathComponent("test.sqlite"))
    }

    private func record(_ id: UUID) -> ConnectionRecord {
      ConnectionRecord(
        id: id, url: URL(string: "https://paperless.example.com/api/")!,
        user: .init(id: 1, isSuperUser: true, username: "preview"))
    }

    @Test("The display name is the friendly name, else the host, else the URL")
    func displayName() {
      let id = UUID()
      #expect(FileProviderDomainSync.displayName(for: server(id, name: "Home")) == "Home")
      #expect(
        FileProviderDomainSync.displayName(for: server(id, name: "  ")) == "paperless.example.com")
      #expect(FileProviderDomainSync.displayName(for: server(id)) == "paperless.example.com")
      #expect(FileProviderDomainSync.displayName(for: server(id, url: "file:///")) == "file:///")
    }

    @Test("A new server gets a domain named after it")
    func addsDomain() async {
      let id = UUID()
      let domains = FakeDomains()
      let sync = confirmed([id: server(id, name: "Home")], domains)

      await sync.reconcile()

      #expect(await domains.calls == ["add \(id.uuidString) Home"])
    }

    @Test("A renamed server's domain is added again under the new name, never removed")
    func renamesInPlace() async {
      let id = UUID()
      let domains = FakeDomains([id.uuidString: "Old"])
      let sync = confirmed([id: server(id, name: "New")], domains)

      await sync.reconcile()

      #expect(await domains.calls == ["add \(id.uuidString) New"])
    }

    @Test("Two servers on one host get distinct names from the reconcile")
    func sameHostServersGetDistinctNames() async {
      let first = UUID()
      let second = UUID()
      let domains = FakeDomains()
      let sync = confirmed([first: server(first), second: server(second)], domains)

      await sync.reconcile()

      let names = await domains.current
      #expect(names.count == 2)
      #expect(Set(names.values).count == 2)
    }

    @Test("A new server with an existing domain's name leaves that domain's name alone")
    func existingNameStaysStable() async {
      let old = UUID()
      let new = UUID()
      let domains = FakeDomains([old.uuidString: "Home"])
      let sync = confirmed(
        [old: server(old, name: "Home"), new: server(new, name: "Home")], domains)

      await sync.reconcile()

      let calls = await domains.calls
      #expect(calls.count == 1)
      #expect(calls.first?.hasPrefix("add \(new.uuidString) Home (") == true)
      #expect(await domains.current[old.uuidString] == "Home")
    }

    @Test("A server seen in an earlier read and then deleted loses its domain")
    func removesSeenThenDeleted() async {
      let kept = UUID()
      let gone = UUID()
      let model = ServerList()
      model.servers = [kept: server(kept), gone: server(gone, name: "Gone")]
      let domains = FakeDomains([
        kept.uuidString: "paperless.example.com", gone.uuidString: "Gone",
      ])
      let sync = following(model, domains)
      await sync.reconcile()
      #expect(await domains.calls.isEmpty)

      model.servers = [kept: server(kept)]
      await sync.reconcile()

      #expect(await domains.calls == ["remove \(gone.uuidString)"])
    }

    @Test("A domain whose server no read in this process has held is kept")
    func unseenDomainIsKept() async {
      let kept = UUID()
      let domains = FakeDomains([kept.uuidString: "paperless.example.com", UUID().uuidString: "Old"])
      let sync = confirmed([kept: server(kept)], domains)

      await sync.reconcile()

      #expect(await domains.calls.isEmpty)
    }

    private struct ReadFailed: Error {}

    @Test("A failed server read removes nothing, even with no servers known")
    func failedReadRemovesNothing() async {
      let domains = FakeDomains([UUID().uuidString: "Home"])
      let sync = FileProviderDomainSync(
        observed: { [:] }, read: { throw ReadFailed() }, allowsRemoval: true, manager: domains)

      await sync.reconcile()

      #expect(await domains.calls.isEmpty)
    }

    @Test("A server list not read from the database on disk never removes a domain")
    func notOnDiskRemovesNothing() async {
      let id = UUID()
      let model = ServerList()
      model.servers = [id: server(id, name: "Home")]
      let domains = FakeDomains([id.uuidString: "Home"])
      let sync = following(model, domains, allowsRemoval: false)
      await sync.reconcile()

      model.servers = [:]
      await sync.reconcile()

      #expect(await domains.calls.isEmpty)
    }

    @Test("A stack over the in-memory database never removes a domain, even of a server it saw")
    func inMemoryStackRemovesNothing() async throws {
      let id = UUID()
      let stack = AppStack(database: try Database.seeded(serverID: id))
      let domains = FakeDomains([id.uuidString: "paperless.example.com"])
      let sync = FileProviderDomainSync(
        connectionManager: stack.connectionManager, database: stack.database, manager: domains)
      await sync.reconcile()

      _ = try stack.database.deleteConnection(id: id)
      try await waitUntil({ stack.connectionManager.connections.isEmpty }, "row never went")
      await sync.reconcile()

      #expect(await domains.calls.isEmpty)
    }

    @Test("A fresh, empty database on disk removes nothing")
    func freshOnDiskDatabaseRemovesNothing() async throws {
      let stack = AppStack(database: try onDiskDatabase())
      let domains = FakeDomains([UUID().uuidString: "Home"])
      let sync = FileProviderDomainSync(
        connectionManager: stack.connectionManager, database: stack.database, manager: domains)

      await sync.reconcile()

      #expect(await domains.calls.isEmpty)
    }

    @Test("On disk, a server seen and then deleted loses its domain")
    func onDiskSeenThenDeletedRemoves() async throws {
      let id = UUID()
      let database = try onDiskDatabase()
      try database.upsertConnection(record(id))
      let stack = AppStack(database: database)
      let domains = FakeDomains()
      let sync = FileProviderDomainSync(
        connectionManager: stack.connectionManager, database: database, manager: domains)
      await sync.reconcile()
      #expect(await domains.current == [id.uuidString: "paperless.example.com"])

      _ = try database.deleteConnection(id: id)
      try await waitUntil({ stack.connectionManager.connections.isEmpty }, "row never went")
      await sync.reconcile()

      #expect(await domains.current.isEmpty)
      #expect(await domains.calls.last == "remove \(id.uuidString)")
    }

    @Test("A pass whose server names are already applied reads nothing and calls nothing")
    func unchangedNamesSkipThePass() async {
      let id = UUID()
      let domains = FakeDomains()
      let sync = confirmed([id: server(id, name: "Home")], domains)

      await sync.reconcile()
      await sync.reconcile()
      await sync.reconcile()

      #expect(sync.readCount == 1)
      #expect(await domains.listCount == 1)
      #expect(await domains.calls == ["add \(id.uuidString) Home"])
    }

    @Test("A failed add is logged once, not recorded as applied, and not retried on its own")
    func failedAddIsLoggedOnce() async {
      let id = UUID()
      let domains = FakeDomains([id.uuidString: "Old"], failAdds: true)
      let sync = confirmed([id: server(id, name: "New")], domains)

      await sync.reconcile()
      // Nothing was applied, so the next pass (on the next change) tries again.
      await sync.reconcile()

      #expect(await domains.calls == ["add \(id.uuidString) New", "add \(id.uuidString) New"])
      #expect(sync.loggedFailures.count == 1)
    }

    @Test("Without a domain manager the sync reads nothing and does nothing")
    func noManagerIsInert() async {
      var reads = 0
      let sync = FileProviderDomainSync(
        observed: { [:] },
        read: {
          reads += 1
          return [:]
        }, allowsRemoval: true, manager: nil)
      sync.start()
      await sync.reconcile()

      #expect(reads == 0)
      #expect(sync.readCount == 0)
    }

    @Test("Started, the sync follows the server list")
    func followsServerList() async throws {
      let model = ServerList()
      let domains = FakeDomains()
      let sync = following(model, domains)
      sync.start()
      defer { sync.stop() }

      let id = UUID()
      model.servers = [id: server(id, name: "Home")]
      try await waitUntil { await domains.current == [id.uuidString: "Home"] }

      model.servers = [id: server(id, name: "Office")]
      try await waitUntil { await domains.current == [id.uuidString: "Office"] }

      model.servers = [:]
      try await waitUntil { await domains.current.isEmpty }
    }
  }

  @MainActor
  @Observable
  private final class ServerList {
    var servers: [UUID: StoredConnection] = [:]
  }

#endif
