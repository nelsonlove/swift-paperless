//
//  MockLibrary.swift
//  AppShared
//
//  A made-up Paperless library written straight into the app-group database
//  and content store, so the File Provider extension (and the app) have
//  something to show with no Paperless server. Debug builds only.
//

#if DEBUG

  import Common
  import DataModel
  import Foundation
  import Networking
  import Persistence
  import SwiftUI
  import os

  /// A fixed fake server: one `server` row, its tags, correspondents, document
  /// types, storage path and documents, and three archive files already in the
  /// content store.
  ///
  /// Every value is fixed, the server id included, so seeding twice gives the
  /// same rows and the same files. All names and titles are made up.
  public enum MockLibrary {
    /// The launch argument that asks the app to seed the library.
    public static let launchArgument = "--seed-mock-library"

    /// Whether `arguments` ask for the seed, in the same form as the app's
    /// other launch arguments: the bare flag, or `--seed-mock-library=<bool>`.
    public static func isRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments)
      -> Bool
    {
      var requested = false
      for argument in arguments {
        if argument == launchArgument {
          requested = true
        } else if argument.hasPrefix("\(launchArgument)=") {
          let value = argument.dropFirst(launchArgument.count + 1).lowercased()
          requested = !(value == "0" || value == "false" || value == "no")
        }
      }
      return requested
    }

    // MARK: - Server

    public static let serverID = UUID(uuidString: "6D0C4B1E-5EED-4A11-8000-00000000C0DE")!
    public static let url = URL(string: "https://paperless.example.com/api/")!
    public static let friendlyName = "Mock Paperless"
    public static let user = User(id: 1, isSuperUser: true, username: "demo")
    /// Known, so `ApiRepository` builds without probing a server that is not there.
    public static let versions = BackendVersions(
      apiVersion: 9, backendVersion: Version(2, 20, 0))
    /// Stored like a real token; nothing checks it.
    public static let token = "mock-token-not-a-secret"

    public static var connection: StoredConnection {
      StoredConnection(
        id: serverID,
        url: url,
        extraHeaders: [],
        user: user,
        friendlyName: friendlyName,
        knownVersions: versions)
    }

    // MARK: - Elements

    public enum TagID {
      public static let inbox: UInt = 1
      public static let tax: UInt = 2
      public static let home: UInt = 3
      public static let insurance: UInt = 4
    }

    public enum CorrespondentID {
      public static let acme: UInt = 1
      public static let northwind: UInt = 2
      public static let library: UInt = 3
    }

    public enum DocumentTypeID {
      public static let invoice: UInt = 1
      public static let letter: UInt = 2
      public static let statement: UInt = 3
    }

    public static let storagePathID: UInt = 1

    public static let tags: [DataModel.Tag] = [
      tag(TagID.inbox, "inbox", color: "#a6cee3", isInbox: true),
      tag(TagID.tax, "tax", color: "#1f78b4"),
      tag(TagID.home, "home", color: "#b2df8a"),
      tag(TagID.insurance, "insurance", color: "#33a02c", parent: TagID.home),
    ]

    public static let correspondents: [Correspondent] = [
      Correspondent(
        id: CorrespondentID.acme, name: "Acme Utilities", slug: "acme-utilities",
        matchingAlgorithm: .none, match: "", isInsensitive: true),
      Correspondent(
        id: CorrespondentID.northwind, name: "Northwind Bank", slug: "northwind-bank",
        matchingAlgorithm: .none, match: "", isInsensitive: true),
      Correspondent(
        id: CorrespondentID.library, name: "City Library", slug: "city-library",
        matchingAlgorithm: .none, match: "", isInsensitive: true),
    ]

    public static let documentTypes: [DocumentType] = [
      DocumentType(
        id: DocumentTypeID.invoice, name: "Invoice", slug: "invoice", match: "",
        matchingAlgorithm: .none, isInsensitive: true),
      DocumentType(
        id: DocumentTypeID.letter, name: "Letter", slug: "letter", match: "",
        matchingAlgorithm: .none, isInsensitive: true),
      DocumentType(
        id: DocumentTypeID.statement, name: "Statement", slug: "statement", match: "",
        matchingAlgorithm: .none, isInsensitive: true),
    ]

    public static let storagePaths: [StoragePath] = [
      StoragePath(
        id: storagePathID, name: "By correspondent and year",
        path: "{correspondent}/{created_year}", slug: "by-correspondent-and-year",
        matchingAlgorithm: .none, match: "", isInsensitive: true)
    ]

    // MARK: - Documents

    /// About fifteen documents across two years. Some have no correspondent,
    /// some no type, one a non-PDF original and no archive.
    public static let documents: [DataModel.Document] = [
      document(
        1, "Electricity bill March 2026", created: (2026, 3, 14),
        correspondent: CorrespondentID.acme, type: DocumentTypeID.invoice,
        tags: [TagID.home], original: "acme-2026-03.pdf", archived: true),
      document(
        2, "Electricity bill February 2026", created: (2026, 2, 13),
        correspondent: CorrespondentID.acme, type: DocumentTypeID.invoice,
        tags: [TagID.home], original: "acme-2026-02.pdf", archived: true),
      document(
        3, "Water bill Q4 2025", created: (2025, 12, 30),
        correspondent: CorrespondentID.acme, type: DocumentTypeID.invoice,
        tags: [TagID.home, TagID.tax], original: "water-2025-q4.pdf", archived: true),
      document(
        4, "Tariff change notice", created: (2025, 9, 2),
        correspondent: CorrespondentID.acme, type: DocumentTypeID.letter,
        tags: [], original: "tariff-notice.pdf", archived: true),
      document(
        5, "Account statement January 2026", created: (2026, 1, 31),
        correspondent: CorrespondentID.northwind, type: DocumentTypeID.statement,
        tags: [TagID.tax], original: "statement-2026-01.pdf", archived: true),
      document(
        6, "Account statement December 2025", created: (2025, 12, 31),
        correspondent: CorrespondentID.northwind, type: DocumentTypeID.statement,
        tags: [TagID.tax], original: "statement-2025-12.pdf", archived: true),
      document(
        7, "Annual interest summary 2025", created: (2026, 1, 15),
        correspondent: CorrespondentID.northwind, type: DocumentTypeID.statement,
        tags: [TagID.tax, TagID.inbox], original: "interest-2025.pdf", archived: true),
      document(
        8, "New debit card letter", created: (2025, 4, 22),
        correspondent: CorrespondentID.northwind, type: DocumentTypeID.letter,
        tags: [], original: "card-letter.pdf", archived: true),
      document(
        9, "Membership renewal", created: (2025, 6, 1),
        correspondent: CorrespondentID.library, type: DocumentTypeID.letter,
        tags: [TagID.inbox], original: "membership.pdf", archived: true),
      document(
        10, "Overdue reminder", created: (2025, 11, 8),
        correspondent: CorrespondentID.library, type: nil,
        tags: [], original: "reminder.pdf", archived: true),
      document(
        11, "Home insurance policy 2026", created: (2026, 1, 5),
        correspondent: nil, type: DocumentTypeID.letter,
        tags: [TagID.home, TagID.insurance], original: "policy-2026.pdf", archived: true),
      document(
        12, "Contents insurance claim form", created: (2025, 8, 19),
        correspondent: nil, type: nil,
        tags: [TagID.insurance], original: "claim-form.pdf", archived: true),
      document(
        13, "Receipt photo hardware store", created: (2025, 5, 10),
        correspondent: nil, type: DocumentTypeID.invoice,
        tags: [TagID.inbox], original: "receipt.jpg", archived: false),
      document(
        14, "Tax return notes 2024", created: (2025, 3, 28),
        correspondent: nil, type: nil,
        tags: [TagID.tax], original: "tax-notes-2024.pdf", archived: true),
      document(
        15, "Scanned postcard", created: (2025, 7, 7),
        correspondent: nil, type: nil,
        tags: [], original: "postcard.pdf", archived: true),
    ]

    /// Which bundled PDF becomes the cached archive of which document. The
    /// names are the files in the repository's `Preview PDFs/` folder.
    public struct ArchiveFixture: Sendable, Equatable {
      public let documentID: UInt
      public let resourceName: String
    }

    public static let archiveFixtures: [ArchiveFixture] = [
      ArchiveFixture(documentID: 1, resourceName: "invoice"),
      ArchiveFixture(documentID: 9, resourceName: "street"),
      ArchiveFixture(documentID: 15, resourceName: "japan"),
    ]

    // MARK: - Seeding

    /// What a seed wrote.
    public struct Report: Sendable, Equatable {
      public var documents = 0
      public var removedDocuments = 0
      public var storedFiles = 0
      public var missingFiles: [String] = []
    }

    /// Write the library into `database` and the archives into `contentStore`,
    /// recorded in `fileIndex` at each document's `modified`, so a download of
    /// them is a cache hit.
    ///
    /// Idempotent: the rows are upserted by fixed ids, the element tables and
    /// the default list are replaced, documents of this server that are not in
    /// the fixtures are deleted, and the files are rewritten in place.
    ///
    /// - Parameter archiveURL: where the PDF named by a fixture's
    ///   `resourceName` is; `nil` skips that file and reports it missing.
    @discardableResult
    public static func seed(
      database: Database,
      contentStore: ContentStore?,
      fileIndex: (any FileIndex)?,
      archiveURL: @Sendable (String) -> URL?
    ) async throws -> Report {
      var report = Report()

      // The cache rows FK-reference the server row, so it goes first.
      try database.upsertConnection(connection.toRecord(needsAuth: false))

      try await database.replaceElements(tags, of: TagRecord.self, serverID: serverID)
      try await database.replaceElements(
        correspondents, of: CorrespondentRecord.self, serverID: serverID)
      try await database.replaceElements(
        documentTypes, of: DocumentTypeRecord.self, serverID: serverID)
      try await database.replaceElements(
        storagePaths, of: StoragePathRecord.self, serverID: serverID)

      let fixtureIDs = Set(documents.map(\.id))
      let stale = try await database.allDocumentIDs(serverID: serverID).subtracting(fixtureIDs)
      try await database.deleteDocuments(serverID: serverID, removedIDs: stale.sorted())
      report.removedDocuments = stale.count

      try await database.upsertDocuments(documents, serverID: serverID)
      report.documents = documents.count

      // The default list, so the app shows the documents before any sync. In
      // the app's default order (added, newest first).
      let queryKey = QueryKey(serverID: serverID, filter: .default)
      let basis = try await database.queryWriteBasis(queryKey: queryKey, serverID: serverID)
      let ordered = documents.sorted { ($0.added ?? $0.created) > ($1.added ?? $1.created) }
      try await database.replaceQueryPage(
        queryKey: queryKey, serverID: serverID, documents: ordered,
        totalCount: UInt(ordered.count), basis: basis)

      guard let contentStore else {
        report.missingFiles = archiveFixtures.map(\.resourceName)
        return report
      }
      for fixture in archiveFixtures {
        guard let document = documents.first(where: { $0.id == fixture.documentID }),
          let modified = document.modified,
          let source = archiveURL(fixture.resourceName)
        else {
          report.missingFiles.append(fixture.resourceName)
          continue
        }
        let key = ContentStore.Key(
          serverID: serverID, versionID: document.currentVersionID, kind: .archive)
        try contentStore.storeData(try Data(contentsOf: source), for: key)
        try await fileIndex?.recordStore(
          key, documentID: document.id, size: contentStore.size(of: key) ?? 0,
          modified: modified, checksum: nil, storedAt: Date())
        report.storedFiles += 1
      }
      return report
    }

    // MARK: - Builders

    private static let calendar: Calendar = {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC")!
      return calendar
    }()

    private static func date(_ ymd: (Int, Int, Int), hour: Int = 9) -> Date {
      calendar.date(
        from: DateComponents(year: ymd.0, month: ymd.1, day: ymd.2, hour: hour))!
    }

    private static func tag(
      _ id: UInt, _ name: String, color: String, isInbox: Bool = false, parent: UInt? = nil
    ) -> DataModel.Tag {
      DataModel.Tag(
        id: id, isInboxTag: isInbox, name: name, slug: name,
        color: HexColor(Color(hex: color) ?? .gray), match: "", matchingAlgorithm: .none,
        isInsensitive: true, parent: parent)
    }

    private static func document(
      _ id: UInt, _ title: String, created: (Int, Int, Int),
      correspondent: UInt?, type: UInt?, tags: [UInt], original: String, archived: Bool
    ) -> DataModel.Document {
      let createdDate = date(created)
      let stem = (original as NSString).deletingPathExtension
      return DataModel.Document(
        id: id,
        title: title,
        documentType: type,
        correspondent: correspondent,
        created: createdDate,
        tags: tags,
        added: createdDate.addingTimeInterval(2 * 3600),
        modified: createdDate.addingTimeInterval(26 * 3600),
        originalFileName: original,
        archivedFileName: archived ? "\(stem).pdf" : nil,
        storagePath: correspondent == nil ? nil : storagePathID,
        owner: .user(user.id),
        pageCount: 1)
    }
  }

#endif
