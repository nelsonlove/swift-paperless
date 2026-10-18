#if canImport(FileProvider)

  import FileProviderCore
  import Foundation
  import Testing

  @testable import AppShared

  /// Records the domain calls and keeps the domain list they imply.
  private actor FakeDomains: FileProviderDomainManaging {
    var current: [String: String]
    private(set) var calls: [String] = []

    init(_ current: [String: String] = [:]) {
      self.current = current
    }

    func domains() async throws -> [DomainReconcile.Domain] {
      current.map { DomainReconcile.Domain(identifier: $0.key, displayName: $0.value) }
    }

    func add(_ domain: DomainReconcile.Domain) async throws {
      calls.append("add \(domain.identifier) \(domain.displayName)")
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
      let sync = FileProviderDomainSync(
        connections: { [id: self.server(id, name: "Home")] }, manager: domains)

      await sync.reconcile()

      #expect(await domains.calls == ["add \(id.uuidString) Home"])
    }

    @Test("A renamed server's domain is added again under the new name, never removed")
    func renamesInPlace() async {
      let id = UUID()
      let domains = FakeDomains([id.uuidString: "Old"])
      let sync = FileProviderDomainSync(
        connections: { [id: self.server(id, name: "New")] }, manager: domains)

      await sync.reconcile()

      #expect(await domains.calls == ["add \(id.uuidString) New"])
    }

    @Test("A domain whose server is gone is removed, and a matching one is left alone")
    func removesOrphan() async {
      let kept = UUID()
      let gone = UUID()
      let domains = FakeDomains([
        kept.uuidString: "paperless.example.com", gone.uuidString: "Gone",
      ])
      let sync = FileProviderDomainSync(
        connections: { [kept: self.server(kept)] }, manager: domains)

      await sync.reconcile()

      #expect(await domains.calls == ["remove \(gone.uuidString)"])
    }

    @Test("Without a domain manager the sync does nothing")
    func noManagerIsInert() async {
      let sync = FileProviderDomainSync(connections: { [:] }, manager: nil)
      sync.start()
      await sync.reconcile()
    }

    @Test("Started, the sync follows the server list")
    func followsServerList() async throws {
      let model = ServerList()
      let domains = FakeDomains()
      let sync = FileProviderDomainSync(connections: { model.servers }, manager: domains)
      sync.start()
      defer { sync.stop() }

      let id = UUID()
      model.servers = [id: server(id, name: "Home")]
      try await eventually { await domains.current == [id.uuidString: "Home"] }

      model.servers = [id: server(id, name: "Office")]
      try await eventually { await domains.current == [id.uuidString: "Office"] }

      model.servers = [:]
      try await eventually { await domains.current.isEmpty }
    }
  }

  @MainActor
  @Observable
  private final class ServerList {
    var servers: [UUID: StoredConnection] = [:]
  }

#endif
