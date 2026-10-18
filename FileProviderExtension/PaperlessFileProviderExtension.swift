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
  private let tasks = TaskBag()

  /// A file in the temporary directory younger than this may be a hand-off
  /// the system has not taken yet (from this or another live instance), so
  /// the sweep at init leaves it.
  static let temporaryFileSafeAge: TimeInterval = 10 * 60

  required init(domain: NSFileProviderDomain) {
    self.domain = domain
    holder = ContextHolder(domain: domain)
    super.init()
    Self.logger.info(
      "File Provider extension started for domain \(domain.identifier.rawValue, privacy: .public)")
    sweepTemporaryDirectory()
    signalIfStateIsMissing()
  }

  /// The system keeps a domain's items and sync anchor across a reinstall of
  /// the app, but the extension's container, which holds its change state, is
  /// new. Until something signals, the system goes on showing what it had.
  /// So an instance with no change state signals the working set: the system
  /// then asks for changes from its old anchor, gets
  /// NSFileProviderErrorSyncAnchorExpired, and enumerates afresh.
  private func signalIfStateIsMissing() {
    guard let url = ExtensionContext.stateURL(for: domain),
      !FileManager.default.fileExists(atPath: url.path),
      let manager = NSFileProviderManager(for: domain)
    else { return }
    Self.logger.notice("File Provider: no change state; signalling the working set")
    manager.signalEnumerator(for: .workingSet) { error in
      if let error {
        Self.logger.error("File Provider: signalling the working set failed: \(error)")
      }
    }
  }

  func invalidate() {
    Self.logger.info("File Provider extension invalidated")
    tasks.cancelAll()
  }

  /// Runs `body` on the main actor, cancelled by `invalidate()` and by the
  /// returned progress.
  private func run(
    _ progress: Progress, _ body: @escaping @MainActor @Sendable (ExtensionContext) async -> Void
  ) {
    let holder = holder
    let task = tasks.run { @MainActor in await body(holder.context) }
    progress.cancellationHandler = { task.cancel() }
  }

  /// "In case the extension or the system crashes between the moment the
  /// completion handler is called and the moment the system unlinks the file,
  /// the file may unexpectedly still be on disk the next time an instance of
  /// the extension is created. The extension is then responsible for deleting
  /// that file." (NSFileProviderReplicatedExtension.h, fetchContents, "File
  /// ownership", lines 343-352 in the iOS 26.5 SDK.)
  ///
  /// Only files older than ``temporaryFileSafeAge``: the system may create a
  /// new instance while another one's hand-off is still waiting to be cloned,
  /// and a fresh file is more likely live than left over.
  private func sweepTemporaryDirectory() {
    guard let manager = NSFileProviderManager(for: domain),
      let directory = try? manager.temporaryDirectoryURL(),
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    let cutoff = Date(timeIntervalSinceNow: -Self.temporaryFileSafeAge)
    let leftovers = entries.filter { url in
      let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      return (modified ?? .distantPast) < cutoff
    }
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
        switch try await context.lookup(identifier) {
        case .found(let item):
          handler.value(item, nil)
        case .absent:
          // NSFileProviderReplicatedExtension.h, itemForIdentifier, "Error
          // cases" (line 272): "If the metadata lookup fails because the item
          // is unknown, the call should fail with the
          // NSFileProviderErrorNoSuchItem error." Only after a successful read.
          handler.value(nil, NSFileProviderError(.noSuchItem))
        }
      } catch {
        // A library that cannot be read is not an unknown item: the same
        // section (line 280) names NSFileProviderErrorServerUnreachable for
        // "the current state of the system / domain" (FileProviderErrors.map).
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
    /// Whether this call answered; a later answer (the fetch finishing after
    /// a cancellation) is dropped.
    let finish: @Sendable (URL?, NSFileProviderItem?, Error?) -> Bool = { url, item, error in
      guard once.claim() else { return false }
      handler.value(url, item, error)
      return true
    }
    // Cancellations: "If the NSProgress returned by this method is cancelled,
    // the extension should call the completion handler with (nil, nil,
    // NSUserCancelledError) in the NSProgress cancellation handler."
    // (NSFileProviderReplicatedExtension.h, fetchContents, lines 396-400.)
    run(progress) { context in
      do {
        let (url, item) = try await Self.fetch(
          itemIdentifier, context: context, progress: progress)
        if !finish(url, item, nil) {
          // Cancelled after the clone was made: nobody takes it.
          try? FileManager.default.removeItem(at: url)
        }
      } catch {
        _ = finish(nil, nil, FileProviderErrors.map(error))
      }
    }
    let cancelTask = progress.cancellationHandler
    progress.cancellationHandler = {
      cancelTask?()
      _ = finish(nil, nil, CocoaError(.userCancelled))
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
    // A library that cannot be read throws LibraryUnavailable, which maps to
    // NSFileProviderErrorServerUnreachable (fetchContents "Error cases", line
    // 382), never to noSuchItem.
    let library = try await context.library(refresh: false)
    guard let document = library.tree.document(for: core),
      let item = context.item(for: core, in: library)
    else {
      // The library was read and does not hold it: "If the download fails
      // because the item was deleted on the server, the call should fail with
      // the NSFileProviderErrorNoSuchItem error."
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
    let cloned = clonefile(source.path, destination.path, 0)
    let cloneError = errno
    // A download that bypassed the content store (no store, or no `modified`
    // to validate it by) left a temporary file of its own; the clone is the
    // only copy needed. The store's own files stay.
    let storeRoot = context.contentStore?.root.standardizedFileURL.path
    if storeRoot.map({ !source.standardizedFileURL.path.hasPrefix($0) }) ?? true {
      try? FileManager.default.removeItem(at: source)
    }
    guard cloned == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: cloneError) ?? .EIO)
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
      let document = try await context.library(refresh: false).tree.document(for: core)
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
    guard let data else { return nil }
    // Decoding and re-encoding an image is work for a background thread.
    return await Task.detached(priority: .utility) { ThumbnailImage.pngOrJPEG(data) }.value
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

  /// Returns a known item unchanged, so the system reverts the local edit;
  /// when the contents changed, with `shouldFetchContent`, so the server's
  /// copy replaces the edited one ("In case there is a content change and the
  /// content of the returned item as described by item does not match the
  /// content from url, the provider should set shouldFetchContent in the
  /// completion handler", NSFileProviderReplicatedExtension.h, modifyItem,
  /// line 614 in the iOS 26.5 SDK). For an item the library does not hold,
  /// not noSuchItem: the modifyItem "Error cases" say that makes "The system
  /// ... attempt to delete the item on disk". The same section lists
  /// NSFileProviderErrorCannotSynchronize for a modification that "cannot be
  /// applied because of the current state of the system / domain"; the system
  /// then shows an error and backs off. A library that cannot be read answers
  /// NSFileProviderErrorServerUnreachable.
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
    let contentsChanged = changedFields.contains(.contents)
    run(progress) { context in
      do {
        switch try await context.lookup(identifier) {
        case .found(let known):
          handler.value(known, [], contentsChanged, nil)
        case .absent:
          handler.value(nil, [], false, NSFileProviderError(.cannotSynchronize))
        }
      } catch {
        handler.value(nil, [], false, FileProviderErrors.map(error))
      }
    }
    return progress
  }

  /// Rejects the deletion of a known item; the deleteItem "Error cases"
  /// (NSFileProviderReplicatedExtension.h) say NSFileProviderErrorDeletionRejected
  /// "will cause the system to re-create the deleted item on disk". An item
  /// the library was read and does not hold is reported deleted, as the same
  /// section asks (line 824): "If the deletion targets an item that is unknown
  /// from the extension because that item may have already been deleted
  /// remotely, then the extension should report a success." A library that
  /// cannot be read is no such confirmation: the same section (line 827)
  /// names NSFileProviderErrorServerUnreachable for "the current state of the
  /// system / domain".
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
      do {
        switch try await context.lookup(identifier) {
        case .found:
          Self.logger.warning("Refused deleteItem: the File Provider is read-only")
          handler.value(NSFileProviderError(.deletionRejected))
        case .absent:
          handler.value(nil)
        }
      } catch {
        handler.value(FileProviderErrors.map(error))
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
