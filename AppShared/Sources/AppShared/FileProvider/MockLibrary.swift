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

    /// Whether `arguments` ask for the seed: the bare flag, or
    /// `--seed-mock-library=<bool>`, read like the app's other boolean flags.
    public static func isRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments)
      -> Bool
    {
      LaunchArguments.flag(launchArgument, in: arguments) ?? false
    }

    // MARK: - Server

    public static let serverID = UUID(uuidString: "6D0C4B1E-5EED-4A11-8000-00000000C0DE")!
    /// A reserved name that never resolves (RFC 2606), so no request, and no
    /// token, ever leaves the device.
    public static let url = URL(string: "https://paperless.invalid/")!
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
      /// Files already fresh in the index, left in place.
      public var keptFiles = 0
      public var missingFiles: [String] = []
    }

    /// The filter the seeded list is stored under, and its sort. The app's
    /// default list when its default sort is one the seed can order by;
    /// otherwise the default pinned to newest added first, so that the key and
    /// the order always agree.
    static var listFilter: FilterState {
      var filter = FilterState.default
      if order(filter.resolvedSorting) == nil {
        filter.sorting = FilterState.Sorting(field: .added, order: .descending)
      }
      return filter
    }

    /// `documents` in the order `sorting` asks for, or `nil` for a sort field
    /// the seed does not order by. Ties break on the id.
    static func order(_ sorting: FilterState.Sorting) -> [DataModel.Document]? {
      let before: (DataModel.Document, DataModel.Document) -> Bool
      switch sorting.field {
      case .added:
        before = { ($0.added ?? .distantPast) < ($1.added ?? .distantPast) }
      case .created:
        before = { $0.created < $1.created }
      case .modified:
        before = { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
      case .title:
        before = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
      default:
        return nil
      }
      let ascending = documents.sorted { lhs, rhs in
        before(lhs, rhs) || (!before(rhs, lhs) && lhs.id < rhs.id)
      }
      return sorting.order.reverse ? Array(ascending.reversed()) : ascending
    }

    /// Write the library into `database` and the archives into `contentStore`,
    /// recorded in `fileIndex` at each document's `modified`, so a download of
    /// them is a cache hit.
    ///
    /// Idempotent: the rows are upserted by fixed ids, the element tables and
    /// the seeded list are replaced, documents of this server that are not in
    /// the fixtures are deleted, and a file already fresh in the index is left
    /// alone. On an existing server row only the fields the fixture owns are
    /// rewritten; the offline mode, cellular sync, identity and extra headers
    /// the user set are kept.
    ///
    /// Not one transaction (the cache tables are written through their own
    /// accessors), so a step that throws removes the server row, which cascades
    /// to every cache row of it; the next seed starts again from nothing.
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
      // The cache rows FK-reference the server row, so it goes first.
      try database.upsertConnection(serverRecord(existing: try database.connection(id: serverID)))
      do {
        return try await seedContent(
          database: database, contentStore: contentStore, fileIndex: fileIndex,
          archiveURL: archiveURL)
      } catch {
        Logger.shared.error("Mock library seed failed, removing its server row: \(error)")
        do {
          try database.deleteConnection(id: serverID)
        } catch {
          Logger.shared.error("Removing the mock library's server row failed: \(error)")
        }
        throw error
      }
    }

    /// The fixture's server row, keeping what the user may have set on an
    /// existing one.
    static func serverRecord(existing: ConnectionRecord?) -> ConnectionRecord {
      var record = connection.toRecord(needsAuth: false)
      if let existing {
        record.offlineBrowsingMode = existing.offlineBrowsingMode
        record.syncOverCellular = existing.syncOverCellular
        record.identity = existing.identity
        record.extraHeaders = existing.extraHeaders
      }
      return record
    }

    private static func seedContent(
      database: Database,
      contentStore: ContentStore?,
      fileIndex: (any FileIndex)?,
      archiveURL: @Sendable (String) -> URL?
    ) async throws -> Report {
      var report = Report()

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

      // The list write upserts the document rows too. Stored as complete, so
      // the app shows the documents before any sync and does not refill.
      let filter = listFilter
      let ordered = order(filter.resolvedSorting) ?? documents
      let queryKey = QueryKey(serverID: serverID, filter: filter)
      let basis = try await database.queryWriteBasis(queryKey: queryKey, serverID: serverID)
      try await database.replaceQueryPage(
        queryKey: queryKey, serverID: serverID, documents: ordered,
        totalCount: UInt(ordered.count), basis: basis)
      try await database.markQueryFillComplete(queryKey: queryKey, serverID: serverID)
      report.documents = ordered.count

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
        if let fileIndex, try await fileIndex.isFresh(key, modified: modified),
          contentStore.exists(key)
        {
          report.keptFiles += 1
          continue
        }
        // A copy, moved into place, so the PDF is never read into memory.
        let temp = FileManager.default.temporaryDirectory
          .appendingPathComponent("mock-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: source, to: temp)
        do {
          try contentStore.store(key, movingFrom: temp)
        } catch {
          try? FileManager.default.removeItem(at: temp)
          throw error
        }
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
