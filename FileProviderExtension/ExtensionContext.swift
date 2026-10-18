//
//  ExtensionContext.swift
//  FileProviderExtension
//

import AppShared
import Common
import DataModel
import FileProvider
import FileProviderCore
import Foundation
import Networking
import Persistence
import os

/// The extension cannot read the library right now: the app-group database
/// could not be opened (only the in-memory fallback exists), the domain is
/// not a server's, or a read failed. Never a reason to call an item gone.
struct LibraryUnavailable: Error, CustomStringConvertible {
  let description: String
}

/// The library as one read saw it: the tree and the sizes of the server's
/// cached files.
struct Library: Sendable {
  let tree: LibraryTree
  let fileSizes: [ContentStore.Key: Int64]
}

/// Everything the extension reads, built lazily on the main actor the first
/// time a callback needs it (plan 4.3).
///
/// It uses the process's ``AppStack`` built with the File Provider role, which
/// skips every launch step (above all closing the app's open sync steps as
/// interrupted), and never starts the session registry, the sync engine or
/// the library watch: the app owns syncing and signalling. When the library
/// cannot be read (the in-memory fallback, a domain that is not a server's,
/// a failed read), ``library(refresh:)`` throws ``LibraryUnavailable`` and the
/// callers answer `NSFileProviderErrorServerUnreachable`, never "no such
/// item", so the system keeps what it has.
@MainActor
final class ExtensionContext {
  static let logger = Logger(
    subsystem: "com.paulgessinger.swift-paperless", category: "FileProvider")

  let domain: NSFileProviderDomain
  /// The server this domain shows: the domain identifier is the server's UUID.
  let serverID: UUID?
  /// Defaults until per-server settings land (plan section 5, PR 9).
  let settings = FileProviderSettings.default

  private var cached: Library?
  /// The library one burst of change pages works from: kept while
  /// `moreComing` is true, so the pages of one burst diff against one read.
  private var burst: Library?
  /// The one creation of the initial change state in flight, which every
  /// caller of ``changeState()`` awaits.
  private var stateCreation: Task<ChangeState, any Error>?

  init(domain: NSFileProviderDomain) {
    self.domain = domain
    serverID = UUID(uuidString: domain.identifier.rawValue)
  }

  /// The process's stack over the on-disk database, or `nil` when only the
  /// in-memory fallback could be built.
  private(set) lazy var stack: AppStack? = {
    let stack = AppStackHolder.sharedWithInMemoryFallback(
      context: "File Provider", role: .fileProviderExtension)
    guard stack.database.fileURL != nil else {
      Self.logger.fault("File Provider: no on-disk database; the library cannot be read")
      return nil
    }
    return stack
  }()

  var contentStore: ContentStore? { stack?.contentReclaimer.store }

  // MARK: Library

  /// The library, reread from the database when `refresh` is set or nothing
  /// is cached. The reads run on the database's queue and the tree is built
  /// off the main actor.
  ///
  /// - Throws: ``LibraryUnavailable`` when the library cannot be read.
  func library(refresh: Bool) async throws -> Library {
    if !refresh, let cached { return cached }
    guard let stack else { throw LibraryUnavailable(description: "no on-disk database") }
    guard let serverID else {
      throw LibraryUnavailable(
        description: "domain \(domain.identifier.rawValue) is not a server identifier")
    }
    let settings = settings
    let rows: LibraryRows
    do {
      rows = try await stack.suspension.performBackgroundWork {
        let database = stack.database
        return LibraryRows(
          documents: try await database.documents(serverID: serverID),
          tags: try await database.elements(TagRecord.self, serverID: serverID),
          correspondents: try await database.elements(
            CorrespondentRecord.self, serverID: serverID),
          documentTypes: try await database.elements(DocumentTypeRecord.self, serverID: serverID),
          storagePaths: try await database.elements(StoragePathRecord.self, serverID: serverID),
          files: try await database.files(serverID: serverID))
      }
    } catch {
      Self.logger.error("File Provider: reading the library failed: \(error)")
      throw LibraryUnavailable(description: "reading the library failed: \(error)")
    }
    let library = await Task.detached(priority: .userInitiated) {
      rows.library(settings: settings)
    }.value
    Self.logger.notice(
      "File Provider: library read, \(rows.documents.count, privacy: .public) documents, \(library.tree.allItems.count, privacy: .public) items"
    )
    cached = library
    return library
  }

  /// The library for the next page of changes: the burst's when a burst is
  /// running, else a fresh read.
  func libraryForChanges() async throws -> Library {
    if let burst { return burst }
    return try await library(refresh: true)
  }

  /// Keeps `library` for the next page of a burst, or ends the burst.
  func setBurst(_ library: Library?) {
    burst = library
  }

  /// The content-store key `download` uses for a document: the archive key
  /// unless the original is asked for (the repository keeps a document with
  /// no archive under the archive key too, see `ApiRepository.streamDownload`).
  func storeKey(for document: Document, kind: ContentStore.Kind? = nil) -> ContentStore.Key? {
    guard let serverID else { return nil }
    let kind = kind ?? (settings.content == .original ? .original : .archive)
    return ContentStore.Key(serverID: serverID, versionID: document.currentVersionID, kind: kind)
  }

  /// The File Provider item for a tree item, or `nil` if the tree has none.
  func item(for identifier: ItemIdentifier, in library: Library) -> NSFileProviderItem? {
    if identifier == .root { return RootItem() }
    guard let treeItem = library.tree.item(for: identifier) else { return nil }
    let document = library.tree.document(for: identifier)
    let size = document.flatMap { storeKey(for: $0) }.flatMap { library.fileSizes[$0] }
    return LibraryItem(treeItem, document: document, size: size)
  }

  enum Lookup {
    case found(NSFileProviderItem)
    /// The library was read and does not hold the item.
    case absent
  }

  /// The current item for a File Provider identifier, from the cached library.
  ///
  /// - Throws: ``LibraryUnavailable`` when the library cannot be read, so an
  ///   unreadable library is never taken for an absent item.
  func lookup(_ identifier: NSFileProviderItemIdentifier) async throws -> Lookup {
    if identifier == .rootContainer { return .found(RootItem()) }
    guard let core = ItemIdentifier(identifier) else { return .absent }
    let library = try await library(refresh: false)
    return item(for: core, in: library).map { .found($0) } ?? .absent
  }

  // MARK: Server

  /// Whether the server's connection is marked as needing a new login.
  var needsAuth: Bool {
    guard let stack, let serverID else { return false }
    return stack.connectionManager.needsAuthIds.contains(serverID)
  }

  /// The server's repository, built through its session as the app builds it
  /// (`ServerSession.prepareRepository(for:)`).
  func repository() async throws -> any Repository & CachingBackend {
    guard let stack, let serverID,
      let stored = stack.connectionManager.connections[serverID]
    else {
      // The server row is gone or unreadable: nothing can be fetched.
      throw NSFileProviderError(.notAuthenticated)
    }
    return try await stack.sessionRegistry.session(for: serverID).prepareRepository(for: stored)
  }

  // MARK: Change state

  /// The change state lives in the extension's own container, one file per
  /// domain, outside the app group: it records what this extension told the
  /// system and nothing else reads it.
  private var stateURL: URL? { Self.stateURL(for: domain) }

  nonisolated static func stateURL(for domain: NSFileProviderDomain) -> URL? {
    guard
      let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return nil }
    return directory.appendingPathComponent(
      "fp-state-\(domain.identifier.rawValue).json", isDirectory: false)
  }

  func loadState() -> ChangeState? {
    guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return nil }
    do {
      return try JSONDecoder().decode(ChangeState.self, from: data)
    } catch {
      Self.logger.error("File Provider: unreadable change state, starting over: \(error)")
      return nil
    }
  }

  func saveState(_ state: ChangeState) throws {
    guard let stateURL else { throw CocoaError(.fileWriteUnknown) }
    try FileManager.default.createDirectory(
      at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
  }

  /// The stored change state, or a new one from the library as it is now.
  /// Creating it is single-flight: callers that arrive while it is being
  /// created await the same creation, so one epoch is saved, not one each.
  func changeState() async throws -> ChangeState {
    if let state = loadState() { return state }
    if let stateCreation { return try await stateCreation.value }
    let creation = Task { @MainActor in
      let library = try await self.library(refresh: true)
      let snapshot = await Task.detached { library.tree.snapshot() }.value
      let state = ChangePager.initialState(current: snapshot)
      try self.saveState(state)
      return state
    }
    stateCreation = creation
    defer { stateCreation = nil }
    return try await creation.value
  }
}

/// What one read of the database returns; Sendable, so the tree can be built
/// off the main actor.
private struct LibraryRows: Sendable {
  let documents: [Document]
  let tags: [Tag]
  let correspondents: [Correspondent]
  let documentTypes: [DocumentType]
  let storagePaths: [StoragePath]
  let files: [FileRecord]

  func library(settings: FileProviderSettings) -> Library {
    let tree = LibraryTree(
      documents: documents, tags: tags, correspondents: correspondents,
      documentTypes: documentTypes, storagePaths: storagePaths, settings: settings)
    var sizes: [ContentStore.Key: Int64] = [:]
    for file in files {
      if let key = file.key { sizes[key] = file.size }
    }
    return Library(tree: tree, fileSizes: sizes)
  }
}

extension ItemIdentifier {
  /// The core identifier for a File Provider identifier: `.rootContainer` is
  /// the root; the working set, the trash and unknown strings have none.
  init?(_ identifier: NSFileProviderItemIdentifier) {
    if identifier == .rootContainer {
      self = .root
    } else if identifier == .workingSet || identifier == .trashContainer {
      return nil
    } else {
      self.init(stringValue: identifier.rawValue)
    }
  }

  var fileProviderIdentifier: NSFileProviderItemIdentifier {
    self == .root ? .rootContainer : NSFileProviderItemIdentifier(stringValue)
  }
}

/// Runs tasks for the extension and its enumerators, forgets each one when it
/// finishes, and cancels the rest on `invalidate()`.
final class TaskBag: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]

  @discardableResult
  func run(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    let id = UUID()
    return lock.withLock {
      let task = Task {
        await body()
        self.remove(id)
      }
      tasks[id] = task
      return task
    }
  }

  private func remove(_ id: UUID) {
    lock.withLock { _ = tasks.removeValue(forKey: id) }
  }

  func cancelAll() {
    let running = lock.withLock {
      let all = Array(tasks.values)
      tasks.removeAll()
      return all
    }
    for task in running { task.cancel() }
  }
}
