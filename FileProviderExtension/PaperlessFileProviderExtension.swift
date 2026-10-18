//
//  PaperlessFileProviderExtension.swift
//  FileProviderExtension
//

import AppShared
import Common
import FileProvider
import FileProviderCore
import Foundation
import ImageIO
import Networking
import UniformTypeIdentifiers
import os

/// The File Provider extension: one domain per configured server, read-only.
///
/// The library is the app-group database the app keeps in sync; the extension
/// reads it through ``ExtensionContext`` and shapes it with FileProviderCore's
/// `LibraryTree`. Content comes from the app-group content store when fresh,
/// else from the server through the server's repository, and is handed over as
/// an APFS clone. Read-only enforcement follows upstream issue #727 Stage 4:
/// items carry no write capabilities, `createItem` fails with
/// `.cannotSynchronize` (keeping the user's file), `modifyItem` reverts a
/// known item and fails others with `.cannotSynchronize`, and `deleteItem`
/// rejects deleting a known item. Every error code is the one the SDK header
/// (NSFileProviderReplicatedExtension.h, each method's "Error cases") names
/// for the case; the comments quote it.
///
/// `init(domain:)` is synchronous and nonisolated and stores only the domain
/// (and sweeps the temporary directory); the database and repository stack is
/// built lazily on the main actor by the first callback that needs it.
final class PaperlessFileProviderExtension: NSObject, NSFileProviderReplicatedExtension,
  NSFileProviderThumbnailing
{
  private static let logger = Logger(
    subsystem: "com.paulgessinger.swift-paperless", category: "FileProvider")

  let domain: NSFileProviderDomain
  private let holder: ContextHolder
  private var tasks: [Task<Void, Never>] = []
  private let lock = NSLock()

  required init(domain: NSFileProviderDomain) {
    self.domain = domain
    holder = ContextHolder(domain: domain)
    super.init()
    Self.logger.info(
      "File Provider extension started for domain \(domain.identifier.rawValue, privacy: .public)")
    sweepTemporaryDirectory()
  }

  func invalidate() {
    Self.logger.info("File Provider extension invalidated")
    lock.withLock {
      for task in tasks { task.cancel() }
      tasks.removeAll()
    }
  }

  /// Runs `body` on the main actor, cancelled by `invalidate()` and by the
  /// returned progress.
  private func run(
    _ progress: Progress, _ body: @escaping @MainActor @Sendable (ExtensionContext) async -> Void
  ) {
    let holder = holder
    let task = Task { @MainActor in
      await body(holder.context)
    }
    lock.withLock { tasks.append(task) }
    progress.cancellationHandler = { task.cancel() }
  }

  /// "In case the extension or the system crashes between the moment the
  /// completion handler is called and the moment the system unlinks the file,
  /// the file may unexpectedly still be on disk the next time an instance of
  /// the extension is created. The extension is then responsible for deleting
  /// that file." (NSFileProviderReplicatedExtension.h, fetchContents, "File
  /// ownership", lines 343-352 in the iOS 26.5 SDK.)
  private func sweepTemporaryDirectory() {
    guard let manager = NSFileProviderManager(for: domain),
      let directory = try? manager.temporaryDirectoryURL(),
      let leftovers = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for url in leftovers {
      try? FileManager.default.removeItem(at: url)
    }
    if !leftovers.isEmpty {
      Self.logger.info(
        "Removed \(leftovers.count, privacy: .public) leftover file(s) from the temporary directory"
      )
    }
  }

  // MARK: Items and enumeration

  func item(
    for identifier: NSFileProviderItemIdentifier,
    request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    let progress = Progress()
    let handler = Handoff(value: completionHandler)
    if identifier == .rootContainer {
      handler.value(RootItem(), nil)
      return progress
    }
    run(progress) { context in
      do {
        guard let core = ItemIdentifier(identifier),
          let tree = try await context.tree(refresh: false),
          let item = context.item(for: core, in: tree)
        else {
          // NSFileProviderReplicatedExtension.h, itemForIdentifier, "Error cases":
          // "If the metadata lookup fails because the item is unknown, the call
          // should fail with the NSFileProviderErrorNoSuchItem error."
          handler.value(nil, NSFileProviderError(.noSuchItem))
          return
        }
        handler.value(item, nil)
      } catch {
        handler.value(nil, FileProviderErrors.map(error))
      }
    }
    return progress
  }

  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier,
    request: NSFileProviderRequest
  ) throws -> NSFileProviderEnumerator {
    switch containerItemIdentifier {
    case .workingSet:
      return LibraryEnumerator(holder: holder, scope: .workingSet)
    case .trashContainer:
      // NSFileProviderReplicatedExtension.h, enumeratorForContainerItemIdentifier,
      // "Error cases": "If containerItemIdentifier is
      // NSFileProviderTrashContainerItemIdentifier and the extension does not
      // support trashing items, then it should fail the call with the
      // NSFeatureUnsupportedError error code from the NSCocoaErrorDomain domain."
      throw CocoaError(.featureUnsupported)
    default:
      guard let core = ItemIdentifier(containerItemIdentifier), core.isContainer else {
        // Same section: an unknown container fails with
        // NSFileProviderErrorNoSuchItem. A folder that does not exist (any
        // more) is found when it is enumerated, which fails the same way.
        throw NSFileProviderError(.noSuchItem)
      }
      return LibraryEnumerator(holder: holder, scope: .container(core))
    }
  }

  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier,
    version requestedVersion: NSFileProviderItemVersion?,
    request: NSFileProviderRequest,
    completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 100)
    let handler = Handoff(value: completionHandler)
    let once = Once()
    let finish: @Sendable (URL?, NSFileProviderItem?, Error?) -> Void = { url, item, error in
      if once.claim() { handler.value(url, item, error) }
    }
    // Cancellations: "If the NSProgress returned by this method is cancelled,
    // the extension should call the completion handler with (nil, nil,
    // NSUserCancelledError) in the NSProgress cancellation handler."
    // (NSFileProviderReplicatedExtension.h, fetchContents, lines 396-400.)
    run(progress) { context in
      do {
        let (url, item) = try await Self.fetch(
          itemIdentifier, context: context, progress: progress)
        finish(url, item, nil)
      } catch {
        finish(nil, nil, FileProviderErrors.map(error))
      }
    }
    let cancelTask = progress.cancellationHandler
    progress.cancellationHandler = {
      cancelTask?()
      finish(nil, nil, CocoaError(.userCancelled))
    }
    return progress
  }

  @MainActor
  private static func fetch(
    _ identifier: NSFileProviderItemIdentifier, context: ExtensionContext, progress: Progress
  ) async throws -> (URL, NSFileProviderItem) {
    guard let core = ItemIdentifier(identifier) else { throw NSFileProviderError(.noSuchItem) }
    guard core.documentID != nil else {
      // A folder has no contents to fetch. Not noSuchItem, which would make
      // the system delete it; NSFileReadNoPermissionError is the error the
      // fetchContents "Error cases" name for content the user cannot read.
      throw CocoaError(.fileReadNoPermission)
    }
    guard let tree = try await context.tree(refresh: false),
      let document = tree.document(for: core),
      let item = context.item(for: core, in: tree)
    else {
      // "If the download fails because the item was deleted on the server,
      // the call should fail with the NSFileProviderErrorNoSuchItem error."
      throw NSFileProviderError(.noSuchItem)
    }

    let original = context.settings.content == .original
    let repository = try await context.repository()
    let source: URL
    if context.needsAuth {
      // Signed out: serve a cached copy, possibly outdated, or ask for a login.
      guard let stored = await repository.storedDownload(document: document, original: original)
      else { throw NSFileProviderError(.notAuthenticated) }
      source = stored
    } else {
      do {
        // `download` answers from the content store without the network when
        // the cached file matches `modified`, and otherwise downloads into the
        // store (ApiRepository.streamDownload).
        source = try await NetworkTransfer.$category.withValue(.documents) {
          try await repository.download(document: document, original: original) { fraction in
            progress.completedUnitCount = Int64(fraction * 100)
          }
        }
      } catch let error as RequestError {
        // Offline or unreachable: an outdated cached copy beats none.
        guard case .connectivity = error,
          let stored = await repository.storedDownload(document: document, original: original)
        else { throw error }
        Self.logger.info(
          "Server unreachable; serving the cached copy of document \(document.id, privacy: .public)"
        )
        source = stored
      }
    }

    guard let manager = NSFileProviderManager(for: context.domain) else {
      throw NSFileProviderError(.serverUnreachable)
    }
    let destination = try manager.temporaryDirectoryURL()
      .appendingPathComponent(UUID().uuidString, isDirectory: false)
      .appendingPathExtension((item.filename as NSString).pathExtension)
    // clonefile(2) rather than FileManager.copyItem, so a fall back to a byte
    // copy cannot go unnoticed: "The system clones and unlinks the received
    // fileContents" and the content store keeps its own file (header, "File
    // ownership").
    guard clonefile(source.path, destination.path, 0) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    progress.completedUnitCount = 100
    return (destination, item)
  }

  // MARK: Thumbnails

  func fetchThumbnails(
    for itemIdentifiers: [NSFileProviderItemIdentifier],
    requestedSize size: CGSize,
    perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
    completionHandler: @escaping (Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
    let perItem = Handoff(value: perThumbnailCompletionHandler)
    let done = Handoff(value: completionHandler)
    run(progress) { context in
      for identifier in itemIdentifiers {
        if Task.isCancelled { break }
        do {
          let data = try await Self.thumbnail(for: identifier, context: context)
          // "If there is no thumbnail for a given item, the
          // perThumbnailCompletionHandler should be called with its imageData
          // and error parameters both set to nil." (NSFileProviderThumbnailing,
          // NSFileProviderReplicatedExtension.h.)
          perItem.value(identifier, data, nil)
        } catch {
          perItem.value(identifier, nil, FileProviderErrors.map(error))
        }
        progress.completedUnitCount += 1
      }
      done.value(Task.isCancelled ? CocoaError(.userCancelled) : nil)
    }
    return progress
  }

  /// The thumbnail the app also shows: the content store's `thumbnail.bin`
  /// when present, else the server's, as PNG unless it already is PNG or JPEG.
  @MainActor
  private static func thumbnail(
    for identifier: NSFileProviderItemIdentifier, context: ExtensionContext
  ) async throws -> Data? {
    guard let core = ItemIdentifier(identifier), core.documentID != nil,
      let tree = try await context.tree(refresh: false),
      let document = tree.document(for: core)
    else { return nil }
    var data: Data?
    if let store = context.contentStore,
      let key = context.storeKey(for: document, kind: .thumbnail), store.exists(key)
    {
      data = try? Data(contentsOf: store.url(for: key))
    }
    if data == nil, !context.needsAuth {
      data = try await NetworkTransfer.$category.withValue(.thumbnails) {
        try await context.repository().thumbnailData(document: document)
      }
    }
    return data.flatMap(ThumbnailImage.pngOrJPEG)
  }

  // MARK: Writes (refused: the extension is read-only)

  /// Refuses the import visibly and keeps the user's file. Returning a nil item
  /// with no error would make the system delete the imported file ("If the
  /// imported item is refused by the extension, it should return nil for the
  /// createdItem without any error. In that case, the source item will be
  /// deleted from disk.", NSFileProviderReplicatedExtension.h, createItem).
  /// The same header lists `NSFileProviderErrorCannotSynchronize` for a
  /// creation that cannot be applied: "the system will present an appropriate
  /// error message and back off until the next time it is signalled", and
  /// NSFileProviderError.h says the system will not retry the item until it is
  /// modified on disk or the extension is updated.
  func createItem(
    basedOn itemTemplate: NSFileProviderItem,
    fields: NSFileProviderItemFields,
    contents url: URL?,
    options: NSFileProviderCreateItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler:
      @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    Self.logger.warning("Refused createItem: the File Provider is read-only")
    completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
    return Progress()
  }

  /// Returns a known item unchanged, so the system reverts the local edit.
  /// For anything else, not noSuchItem: the modifyItem "Error cases"
  /// (NSFileProviderReplicatedExtension.h) say that makes "The system ...
  /// attempt to delete the item on disk". The same section lists
  /// NSFileProviderErrorCannotSynchronize for a modification that "cannot be
  /// applied because of the current state of the system / domain"; the system
  /// then shows an error and backs off.
  func modifyItem(
    _ item: NSFileProviderItem,
    baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields,
    contents newContents: URL?,
    options: NSFileProviderModifyItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler:
      @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    Self.logger.warning("Refused modifyItem: the File Provider is read-only")
    let progress = Progress()
    let handler = Handoff(value: completionHandler)
    let identifier = item.itemIdentifier
    run(progress) { context in
      if let known = await Self.knownItem(identifier, context: context) {
        handler.value(known, [], false, nil)
      } else {
        handler.value(nil, [], false, NSFileProviderError(.cannotSynchronize))
      }
    }
    return progress
  }

  /// The current item for an identifier, or `nil` if the library has none
  /// (or cannot be read).
  @MainActor
  private static func knownItem(
    _ identifier: NSFileProviderItemIdentifier, context: ExtensionContext
  ) async -> NSFileProviderItem? {
    if identifier == .rootContainer { return RootItem() }
    guard let core = ItemIdentifier(identifier),
      let tree = try? await context.tree(refresh: false)
    else { return nil }
    return context.item(for: core, in: tree)
  }

  /// Rejects the deletion of a known item; the deleteItem "Error cases"
  /// (NSFileProviderReplicatedExtension.h) say NSFileProviderErrorDeletionRejected
  /// "will cause the system to re-create the deleted item on disk". An unknown
  /// item is reported deleted, as the same section asks: "If the deletion
  /// targets an item that is unknown from the extension because that item may
  /// have already been deleted remotely, then the extension should report a
  /// success."
  func deleteItem(
    identifier: NSFileProviderItemIdentifier,
    baseVersion version: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler: @escaping (Error?) -> Void
  ) -> Progress {
    let progress = Progress()
    let handler = Handoff(value: completionHandler)
    run(progress) { context in
      if await Self.knownItem(identifier, context: context) != nil {
        Self.logger.warning("Refused deleteItem: the File Provider is read-only")
        handler.value(NSFileProviderError(.deletionRejected))
      } else {
        handler.value(nil)
      }
    }
    return progress
  }
}

/// Builds the main-actor context on first use and hands the same one to the
/// extension and its enumerators, which the system creates on other threads.
final class ContextHolder: @unchecked Sendable {
  let domain: NSFileProviderDomain

  init(domain: NSFileProviderDomain) {
    self.domain = domain
  }

  @MainActor lazy var context = ExtensionContext(domain: domain)
}

/// Calls a completion handler at most once, whichever path gets there first.
final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.withLock {
      defer { claimed = true }
      return !claimed
    }
  }
}

/// Thumbnail bytes the system can show: PNG and JPEG pass through; anything
/// else ImageIO can decode (paperless serves WebP) is re-encoded as PNG.
/// Whether Files would take WebP as it is was not checked.
enum ThumbnailImage {
  static func pngOrJPEG(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source) as String?
    else { return nil }
    if type == UTType.png.identifier || type == UTType.jpeg.identifier { return data }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
  }
}
