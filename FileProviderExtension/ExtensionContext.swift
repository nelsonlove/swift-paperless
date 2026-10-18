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

/// Everything the extension reads, built lazily on the main actor the first
/// time a callback needs it (plan 4.3).
///
/// It uses the process's ``AppStack`` and never starts the session registry,
/// the sync engine, the launch maintenance or the library watch: the app owns
/// syncing and signalling. When the stack is the in-memory fallback (the
/// app-group database could not be opened), ``tree(refresh:)`` returns `nil`
/// and the callers enumerate nothing and report no deletions, because an
/// empty in-memory library says nothing about what the server holds.
@MainActor
final class ExtensionContext {
  static let logger = Logger(
    subsystem: "com.paulgessinger.swift-paperless", category: "FileProvider")

  let domain: NSFileProviderDomain
  /// The server this domain shows: the domain identifier is the server's UUID.
  let serverID: UUID?
  /// Defaults until per-server settings land (plan section 5, PR 9).
  let settings = FileProviderSettings.default

  private var cachedTree: LibraryTree?
  /// Sizes of the cached document files of this server, by store key.
  private var fileSizes: [ContentStore.Key: Int64] = [:]

  init(domain: NSFileProviderDomain) {
    self.domain = domain
    serverID = UUID(uuidString: domain.identifier.rawValue)
  }

  /// The process's stack over the on-disk database, or `nil` when only the
  /// in-memory fallback could be built.
  private(set) lazy var stack: AppStack? = {
    let stack = AppStackHolder.sharedWithInMemoryFallback(context: "File Provider")
    guard stack.database.fileURL != nil else {
      Self.logger.fault("File Provider: no on-disk database; enumerating nothing")
      return nil
    }
    return stack
  }()

  var contentStore: ContentStore? { stack?.contentReclaimer.store }

  // MARK: Library

  /// The library tree, reread from the database when `refresh` is set or no
  /// tree is cached. `nil` over the in-memory fallback or for a domain whose
  /// identifier is not a server UUID.
  func tree(refresh: Bool) async throws -> LibraryTree? {
    if !refresh, let cachedTree { return cachedTree }
    guard let stack, let serverID else { return nil }
    let settings = settings
    let (tree, sizes) = try await stack.suspension.performBackgroundWork {
      let database = stack.database
      let documents = try await database.documents(serverID: serverID)
      let tags = try await database.elements(TagRecord.self, serverID: serverID)
      let correspondents = try await database.elements(
        CorrespondentRecord.self, serverID: serverID)
      let documentTypes = try await database.elements(
        DocumentTypeRecord.self, serverID: serverID)
      let storagePaths = try await database.elements(StoragePathRecord.self, serverID: serverID)
      let files = try await database.allFiles()
      let tree = LibraryTree(
        documents: documents, tags: tags, correspondents: correspondents,
        documentTypes: documentTypes, storagePaths: storagePaths, settings: settings)
      var sizes: [ContentStore.Key: Int64] = [:]
      for file in files where file.serverId == serverID {
        if let key = file.key { sizes[key] = file.size }
      }
      return (tree, sizes)
    }
    cachedTree = tree
    fileSizes = sizes
    return tree
  }

  /// The content-store key `download` uses for a document: the archive key
  /// unless the original is asked for (the repository keeps a document with
  /// no archive under the archive key too, see `ApiRepository.streamDownload`).
  func storeKey(for document: Document, kind: ContentStore.Kind? = nil) -> ContentStore.Key? {
    guard let serverID else { return nil }
    let kind = kind ?? (settings.content == .original ? .original : .archive)
    return ContentStore.Key(serverID: serverID, versionID: document.currentVersionID, kind: kind)
  }

  /// The size of a document's cached file, when it is cached.
  func cachedSize(of document: Document) -> Int64? {
    storeKey(for: document).flatMap { fileSizes[$0] }
  }

  /// The File Provider item for a tree item, or `nil` if the tree has none.
  func item(for identifier: ItemIdentifier, in tree: LibraryTree) -> NSFileProviderItem? {
    if identifier == .root { return RootItem() }
    guard let treeItem = tree.item(for: identifier) else { return nil }
    let document = tree.document(for: identifier)
    return LibraryItem(
      treeItem, document: document, size: document.flatMap { cachedSize(of: $0) })
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
  private var stateURL: URL? {
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
