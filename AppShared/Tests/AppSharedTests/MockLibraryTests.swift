#if DEBUG

  import Common
  import DataModel
  import Foundation
  import Persistence
  import Testing

  @testable import AppShared

  @Suite
  struct MockLibraryTests {
    /// The repository's `Preview PDFs/` folder, which the app bundles in debug builds.
    static let previewPDFs = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // AppSharedTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // AppShared
      .deletingLastPathComponent()  // repository root
      .appendingPathComponent("Preview PDFs", isDirectory: true)

    static func pdf(_ name: String) -> URL? {
      let url = previewPDFs.appendingPathComponent("\(name).pdf")
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    struct Fixture {
      let database: Database
      let store: ContentStore
      let reclaimer: ContentReclaimer
      let root: URL
    }

    static func makeFixture() throws -> Fixture {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MockLibraryTests-\(UUID().uuidString)", isDirectory: true)
      let database = try Database.inMemory()
      let store = try ContentStore(root: root)
      return Fixture(
        database: database, store: store,
        reclaimer: ContentReclaimer(database: database, store: store), root: root)
    }

    @Test("The launch argument is read like the app's other launch arguments")
    func launchArgument() {
      #expect(MockLibrary.isRequested(["app", "--seed-mock-library"]))
      #expect(MockLibrary.isRequested(["app", "--seed-mock-library=1"]))
      #expect(!MockLibrary.isRequested(["app", "--seed-mock-library=false"]))
      #expect(!MockLibrary.isRequested(["app", "--preview-mode"]))
    }

    @Test("The fixtures cover the cases the File Provider tree must handle")
    func fixtureShape() {
      let documents = MockLibrary.documents
      #expect(documents.count == 15)
      #expect(Set(documents.map(\.id)).count == documents.count)
      #expect(documents.contains { $0.correspondent == nil })
      #expect(documents.contains { $0.documentType == nil })
      #expect(documents.contains { $0.tags.isEmpty })
      #expect(
        documents.contains {
          $0.archivedFileName == nil && !($0.originalFileName ?? "").hasSuffix(".pdf")
        })
      let years = Set(documents.map { Calendar(identifier: .gregorian).component(.year, from: $0.created) })
      #expect(years.count == 2)
      #expect(MockLibrary.tags.first { $0.name == "insurance" }?.parent == MockLibrary.TagID.home)
      for fixture in MockLibrary.archiveFixtures {
        #expect(Self.pdf(fixture.resourceName) != nil, "missing \(fixture.resourceName).pdf")
      }
    }

    @Test("Seeding writes the server, elements, documents and cached archives, twice the same")
    func seedIsCompleteAndIdempotent() async throws {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let database = fixture.database
      let serverID = MockLibrary.serverID

      for run in 0..<2 {
        let report = try await MockLibrary.seed(
          database: database, contentStore: fixture.store, fileIndex: fixture.reclaimer,
          archiveURL: Self.pdf)
        #expect(report.documents == 15)
        // The second run finds the files fresh and leaves them.
        #expect(report.storedFiles == (run == 0 ? 3 : 0))
        #expect(report.keptFiles == (run == 0 ? 0 : 3))
        #expect(report.missingFiles.isEmpty)
      }

      let connections = try database.allConnections()
      #expect(connections.count == 1)
      let record = try #require(connections.first)
      #expect(record.id == serverID)
      #expect(record.url == MockLibrary.url)
      #expect(record.friendlyName == "Mock Paperless")
      #expect(record.user.username == "demo")
      #expect(StoredConnection(record: record).knownVersions == MockLibrary.versions)

      #expect(try await database.elements(TagRecord.self, serverID: serverID).count == 4)
      #expect(try await database.elements(CorrespondentRecord.self, serverID: serverID).count == 3)
      #expect(try await database.elements(DocumentTypeRecord.self, serverID: serverID).count == 3)
      #expect(try await database.elements(StoragePathRecord.self, serverID: serverID).count == 1)
      #expect(try await database.documentCount(serverID: serverID) == 15)
      #expect(
        try await database.allDocumentIDs(serverID: serverID)
          == Set(MockLibrary.documents.map(\.id)))

      let queryKey = QueryKey(serverID: serverID, filter: MockLibrary.listFilter)
      #expect(try await database.queryFillCompletedAt(queryKey: queryKey, serverID: serverID) != nil)
      let expectedOrder = try #require(
        MockLibrary.order(MockLibrary.listFilter.resolvedSorting)).map(\.id)
      let listed = try await database.queryDocuments(
        queryKey: queryKey, serverID: serverID, limit: 100, offset: 0)
      #expect(listed.map(\.id) == expectedOrder)
      #expect(listed.allSatisfy { $0.document != nil })

      let stored = try await database.document(serverID: serverID, id: 1)
      #expect(stored == MockLibrary.documents.first { $0.id == 1 })

      let files = try await database.allFiles()
      #expect(files.count == 3)
      for archive in MockLibrary.archiveFixtures {
        let document = try #require(MockLibrary.documents.first { $0.id == archive.documentID })
        let key = ContentStore.Key(
          serverID: serverID, versionID: document.currentVersionID, kind: .archive)
        #expect(fixture.store.exists(key))
        let source = try #require(Self.pdf(archive.resourceName))
        #expect(try Data(contentsOf: fixture.store.url(for: key)) == Data(contentsOf: source))
        // The download path's hit test: fresh at the document's `modified`.
        #expect(try await fixture.reclaimer.isFresh(key, modified: try #require(document.modified)))
      }
    }

    @Test("Seeding removes documents of the mock server that are not fixtures")
    func seedRemovesStrayDocuments() async throws {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      try await MockLibrary.seed(
        database: fixture.database, contentStore: nil, fileIndex: nil, archiveURL: { _ in nil })
      var stray = MockLibrary.documents[0]
      stray.id = 999
      try await fixture.database.upsertDocuments([stray], serverID: MockLibrary.serverID)

      let report = try await MockLibrary.seed(
        database: fixture.database, contentStore: nil, fileIndex: nil, archiveURL: { _ in nil })

      #expect(report.removedDocuments == 1)
      #expect(report.storedFiles == 0)
      #expect(report.missingFiles.count == 3)
      #expect(try await fixture.database.documentCount(serverID: MockLibrary.serverID) == 15)
    }

    @Test("A seed that fails part way leaves no mock server behind")
    func failedSeedRemovesServer() async throws {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let missing = fixture.root.appendingPathComponent("no-such.pdf")

      await #expect(throws: (any Error).self) {
        try await MockLibrary.seed(
          database: fixture.database, contentStore: fixture.store,
          fileIndex: fixture.reclaimer, archiveURL: { _ in missing })
      }

      #expect(try fixture.database.allConnections().isEmpty)
      #expect(try await fixture.database.documentCount(serverID: MockLibrary.serverID) == 0)
      #expect(
        try await fixture.database.elements(TagRecord.self, serverID: MockLibrary.serverID)
          .isEmpty)
    }

    @Test("Seeding keeps what the user set on the mock server")
    func seedKeepsUserSettings() async throws {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      try await MockLibrary.seed(
        database: fixture.database, contentStore: nil, fileIndex: nil, archiveURL: { _ in nil })
      var record = try #require(try fixture.database.connection(id: MockLibrary.serverID))
      record.offlineBrowsingMode = OfflineBrowsingMode.entireLibrary.rawValue
      record.syncOverCellular = true
      record.identity = "made-up-identity"
      record.friendlyName = "Renamed"
      record.needsAuth = true
      try fixture.database.upsertConnection(record)

      try await MockLibrary.seed(
        database: fixture.database, contentStore: nil, fileIndex: nil, archiveURL: { _ in nil })

      let after = try #require(try fixture.database.connection(id: MockLibrary.serverID))
      #expect(after.offlineBrowsingMode == OfflineBrowsingMode.entireLibrary.rawValue)
      #expect(after.syncOverCellular)
      #expect(after.identity == "made-up-identity")
      // The fixture owns these.
      #expect(after.friendlyName == MockLibrary.friendlyName)
      #expect(after.url == MockLibrary.url)
      #expect(!after.needsAuth)
    }

    @Test("The list order follows the sort its key is built from")
    func listOrderMatchesSort() throws {
      let added = try #require(
        MockLibrary.order(.init(field: .added, order: .descending)))
      #expect(added.map(\.added) == added.map(\.added).sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) })
      let title = try #require(MockLibrary.order(.init(field: .title, order: .ascending)))
      #expect(title.first?.title == "Account statement December 2025")
      #expect(MockLibrary.order(.init(field: .asn, order: .ascending)) == nil)
    }

    @Test("Boolean launch flags read the same for every flag")
    func launchFlags() {
      #expect(LaunchArguments.flag("--x", in: ["--x"]) == true)
      #expect(LaunchArguments.flag("--x", in: ["--x=no"]) == false)
      #expect(LaunchArguments.flag("--x", in: ["--x=0", "--x=yes"]) == true)
      #expect(LaunchArguments.flag("--x", in: ["--xy", "--y"]) == nil)
    }

    @Test("A fresh launch's reclaim keeps the seeded files")
    func reclaimKeepsSeededFiles() async throws {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      try await MockLibrary.seed(
        database: fixture.database, contentStore: fixture.store, fileIndex: fixture.reclaimer,
        archiveURL: Self.pdf)

      let report = await fixture.reclaimer.run(reason: .launch)

      #expect(report.removedFiles == 0)
      #expect(try await fixture.database.allFiles().count == 3)
    }
  }

#endif
