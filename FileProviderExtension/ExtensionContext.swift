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

/// The library as one read saw it: the tree, the sizes of the server's cached
/// files, and what the change pages and the working-set pages need, computed
/// once per read off the main actor.
struct Library: Sendable {
  let tree: LibraryTree
  let fileSizes: [ContentStore.Key: Int64]
  /// Every item except the root, with each item's metadata stamp.
  let snapshot: TreeSnapshot
  /// The working set in ``ItemPager`` key order.
  let workingSet: [TreeItem]
}

/// The server as the database has it now.
struct ServerRow: Sendable {
  let stored: StoredConnection
  let needsAuth: Bool
}

/// Everything the extension reads, built lazily on the main actor the first
/// time a callback needs it (plan 4.3).
///
/// It uses the process's ``AppStack`` built with the File Provider role, which
/// skips every launch step (above all closing the app's open sync steps as
/// interrupted) and every cache upkeep, and never starts the session
/// registry, the sync engine or the library watch: the app owns syncing and
/// signalling. When the library cannot be read (the in-memory fallback, a
/// domain that is not a server's, a failed read), ``library(refresh:)``
/// throws ``LibraryUnavailable`` and the callers answer
/// `NSFileProviderErrorServerUnreachable`, never "no such item", so the
/// system keeps what it has.
///
/// The database is shared with the app, which writes it from another
/// process, so nothing the extension keeps in memory is trusted for long: the
/// library is reread at the start of each enumeration and change burst, and
/// the server row (URL, credentials' account, needs-auth) is read from the
/// database each time a fetch or a thumbnail needs it, never from the
/// connection manager, whose observation only sees this process's writes.
///
/// Database work runs inside ``work(_:)``: the suspension controller is
/// attached as for a process that is always in the background, so the writer
/// is open, and an expiring activity held, only while that work runs.
@MainActor
final class ExtensionContext {
  nonisolated static let logger = Logger(
    subsystem: "com.paulgessinger.swift-paperless", category: "FileProvider")

  let domain: NSFileProviderDomain
  /// The server this domain shows: the domain identifier is the server's UUID.
  let serverID: UUID?
  /// Defaults until per-server settings land (plan section 5, PR 9).
  let settings = FileProviderSettings.default

  /// How long the library of a change burst is kept for its next page. The
  /// system asks for the next page right after the last; a later call
  /// belongs to a new signal and rereads.
  static let burstLifetime: TimeInterval = 30

  /// The library reads: single-flight, and never back in time.
  private let reads = FreshRead<Library>()
  /// What one burst of change pages works from: the library, kept while
  /// `moreComing` is true so the pages of one burst diff against one read
  /// (never one older than the newest cached read), and the change state as
  /// last saved, so a page neither reads nor decodes the state file. Cleared
  /// when the burst ends, fails, is cancelled or is invalidated, and expires
  /// after ``burstLifetime``.
  private var burst = ChangeBurst<Library>(lifetime: ExtensionContext.burstLifetime)
  /// The one creation of the initial change state in flight, which every
  /// caller of ``changeState()`` joins.
  private let stateCreation = TaskSlot<ChangeState, any Error>()

  init(domain: NSFileProviderDomain) {
    self.domain = domain
    serverID = UUID(uuidString: domain.identifier.rawValue)
  }

  /// The process's stack over the on-disk database, or `nil` when only the
  /// in-memory fallback could be built.
  ///
  /// Building it attaches the process's suspension controller for an
  /// extension: always in the background, with time from an expiring
  /// activity, and the writer suspended at once. An extension gets no
  /// `UIApplication` lifecycle notifications, and the system may suspend it
  /// whenever it is not answering a call, so the writer must be closed by
  /// default and opened only by counted work (``work(_:)``), never left open
  /// for iOS to find at suspension (`0xDEAD10CC`).
  private(set) lazy var stack: AppStack? = {
    let stack = AppStackHolder.sharedWithInMemoryFallback(
      context: "File Provider", role: .fileProviderExtension)
    guard stack.database.fileURL != nil else {
      Self.logger.fault("File Provider: no on-disk database; the library cannot be read")
      return nil
    }
    stack.suspension.attach(
      isInBackground: true,
      requestTime: ExpiringActivityTime.request(reason: "File Provider database work"))
    stack.suspension.didEnterBackground()
    return stack
  }()

  var contentStore: ContentStore? { stack?.contentReclaimer.store }

  /// Runs `body` as one piece of database work: the writer is open and an
  /// expiring activity is held while it runs (see ``stack``). Every database
  /// read and write of the extension, and every repository call that may
  /// write (a download records its file, a 401 marks the server), runs in
  /// one.
  func work<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
    guard let stack else { return try await body() }
    return try await stack.suspension.performBackgroundWork(body)
  }

  // MARK: Library

  /// The library: a fresh read when `refresh` is set (one that started after
  /// this call, shared with the callers that asked meanwhile), else the
  /// newest read so far, or a read when there is none. Never a library older
  /// than one already handed out.
  ///
  /// - Throws: ``LibraryUnavailable`` when the library cannot be read.
  func library(refresh: Bool) async throws -> Library {
    refresh ? try await reads.fresh(readClosure) : try await reads.cachedOrFresh(readClosure)
  }

  /// The one read every library request hands to ``reads``.
  private var readClosure: @MainActor () async throws -> Library {
    { [weak self] in
      guard let self else { throw CancellationError() }
      return try await self.readLibrary()
    }
  }

  /// One read of the database. The reads run on the database's queue and the
  /// library is built off the main actor.
  private func readLibrary() async throws -> Library {
    guard let stack else { throw LibraryUnavailable(description: "no on-disk database") }
    guard let serverID else {
      throw LibraryUnavailable(
        description: "domain \(domain.identifier.rawValue) is not a server identifier")
    }
    let settings = settings
    let rows: LibraryRows
    do {
      rows = try await work {
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
      "File Provider: library read, \(rows.documents.count, privacy: .public) documents")
    return library
  }

  /// The library for the next page of changes, with the generation of its
  /// read and, inside a burst, the runs that remain (the page's plan):
  /// the burst's while a burst is running and young and no newer read has
  /// been cached since; the newer cached library, at its generation and with
  /// no plan, when a lookup or an enumeration read the library meanwhile;
  /// else (a new burst) a fresh read.
  func libraryForChanges() async throws -> (
    library: Library, generation: UInt64, plan: [[TreeDiff.Change]]?
  ) {
    let newest = reads.cached.map { (library: $0, generation: reads.cachedGeneration) }
    switch burst.source(at: Date(), newest: newest) {
    case .burst(let library, let generation, let plan):
      return (library, generation, plan)
    case .cached(let library, let generation):
      return (library, generation, nil)
    case .read:
      let entry = try await reads.freshEntry(readClosure)
      return (entry.value, entry.generation, nil)
    }
  }

  /// The change state for a page asked from `anchor`: the burst's, as it
  /// last saved it, when the page continues the burst from its anchor; else
  /// the stored one (a re-ask from the previous anchor needs the previous
  /// snapshot, which the burst does not keep).
  func stateForChanges(from anchor: Data) async -> ChangeState? {
    if let state = burst.state(at: Date(), for: anchor) { return state }
    return await loadState()
  }

  /// Keeps `library` (from the read of `generation`), `state` (as saved) and
  /// the runs that remain for the next page of a burst.
  func continueBurst(
    with library: Library, generation: UInt64, state: ChangeState, plan: [[TreeDiff.Change]]
  ) {
    burst.keep(library: library, generation: generation, state: state, plan: plan, at: Date())
  }

  /// Ends the burst: its library and state are not used again.
  func endBurst() {
    burst.end(at: Date())
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

  /// The server row as the database has it now, or `nil` when it is gone.
  /// Read each time it is needed: the app adds, edits, signs in and signs out
  /// servers from its own process, which this process's observation of the
  /// table never sees. The read runs on the database's queue, so the main
  /// actor never waits on the app's writer lock. Call it inside ``work(_:)``.
  ///
  /// - Throws: ``LibraryUnavailable`` when the row cannot be read, which the
  ///   callers answer with NSFileProviderErrorServerUnreachable.
  func serverRow() async throws -> ServerRow? {
    guard let stack, let serverID else { return nil }
    let record: ConnectionRecord?
    do {
      record = try await stack.database.fetchConnection(id: serverID)
    } catch {
      Self.logger.error("File Provider: reading the server row failed: \(error)")
      throw LibraryUnavailable(description: "reading the server row failed: \(error)")
    }
    guard let record else { return nil }
    return ServerRow(stored: StoredConnection(record: record), needsAuth: record.needsAuth)
  }

  /// The server's repository for `server`, built through its session as the
  /// app builds it (`ServerSession.prepareRepository(for:)`); a changed URL,
  /// token or header rebuilds it. The extension's sessions do no cache upkeep
  /// (`AppStack.Role.fileProviderExtension`).
  func repository(for server: ServerRow) async throws -> any Repository & CachingBackend {
    guard let stack else { throw NSFileProviderError(.notAuthenticated) }
    return try await stack.sessionRegistry.session(for: server.stored.id)
      .prepareRepository(for: server.stored)
  }

  /// The stored copy of `document`'s content, if the content store has one,
  /// and whether the index says it is current for the document's `modified`.
  /// No network and no repository. Call it inside ``work(_:)``.
  func storedCopy(of document: Document) async -> (url: URL, isFresh: Bool)? {
    guard let stack, let store = contentStore, let key = storeKey(for: document),
      store.exists(key)
    else { return nil }
    let url = store.url(for: key)
    guard let modified = document.modified else { return (url, false) }
    let fresh = (try? await stack.contentReclaimer.isFresh(key, modified: modified)) ?? false
    if fresh {
      // As a download's cache hit records it; a failure costs only the stamp.
      try? await stack.contentReclaimer.recordAccess(key, at: Date())
    }
    return (url, fresh)
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

  /// The stored change state, read and decoded off the main actor.
  func loadState() async -> ChangeState? {
    guard let stateURL else { return nil }
    return await Task.detached(priority: .userInitiated) {
      guard let data = try? Data(contentsOf: stateURL) else { return nil }
      do {
        return try JSONDecoder().decode(ChangeState.self, from: data)
      } catch {
        Self.logger.error("File Provider: unreadable change state, starting over: \(error)")
        return nil
      }
    }.value
  }

  /// Encodes and writes the change state off the main actor.
  func saveState(_ state: ChangeState) async throws {
    guard let stateURL else { throw CocoaError(.fileWriteUnknown) }
    try await Task.detached(priority: .userInitiated) {
      try FileManager.default.createDirectory(
        at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }.value
  }

  /// The stored change state, or a new one from the library as it is now.
  /// Creating it is single-flight (`TaskSlot`): callers that arrive while it
  /// is being created join the same creation, so one epoch is saved, not one
  /// each.
  func changeState() async throws -> ChangeState {
    if let state = await loadState() { return state }
    return try await stateCreation.joinOrStart { [weak self] in
      guard let self else { throw CancellationError() }
      // A creation that finished while this caller loaded saved one already.
      if let state = await self.loadState() { return state }
      let library = try await self.library(refresh: true)
      let state = ChangePager.initialState(current: library.snapshot)
      try await self.saveState(state)
      return state
    }
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
    return Library(
      tree: tree, fileSizes: sizes,
      snapshot: tree.snapshot(metadata: { LibraryItem.metadataStamp(for: $0) }),
      workingSet: ItemPager.sortedByKey(tree.workingSet, key: \.identifier.stringValue))
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
