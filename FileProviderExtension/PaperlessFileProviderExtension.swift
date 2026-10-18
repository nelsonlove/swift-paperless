//
//  PaperlessFileProviderExtension.swift
//  FileProviderExtension
//

import FileProvider
import UniformTypeIdentifiers
import os

/// The File Provider extension: one domain per configured server.
///
/// This is the scaffolding stage. The root enumerates nothing and every write
/// is refused, so the target builds, embeds and loads before any library code
/// lands. Read-only enforcement follows upstream issue #727 Stage 4: items
/// carry no write capabilities, `createItem` fails with
/// `.cannotSynchronize` (keeping the user's file), `modifyItem` reverts a
/// known item and fails others with `.cannotSynchronize`, and `deleteItem`
/// rejects deleting the root. Every error code is the one the SDK header
/// (NSFileProviderReplicatedExtension.h, each method's "Error cases") names
/// for the case; the comments quote it.
///
/// `init(domain:)` is synchronous and nonisolated and stores only the domain.
/// The database and repository stack is built lazily on the main actor when
/// the library is enumerated (a later stage); nothing here touches it.
final class PaperlessFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
  private static let logger = Logger(
    subsystem: "com.paulgessinger.swift-paperless", category: "FileProvider")

  let domain: NSFileProviderDomain

  required init(domain: NSFileProviderDomain) {
    self.domain = domain
    super.init()
    Self.logger.info("File Provider extension started for domain \(domain.identifier.rawValue, privacy: .public)")
  }

  func invalidate() {
    Self.logger.info("File Provider extension invalidated")
  }

  // MARK: Items and enumeration

  func item(
    for identifier: NSFileProviderItemIdentifier,
    request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    if identifier == .rootContainer {
      completionHandler(RootItem(), nil)
    } else {
      // NSFileProviderReplicatedExtension.h, itemForIdentifier, "Error cases":
      // "If the metadata lookup fails because the item is unknown, the call
      // should fail with the NSFileProviderErrorNoSuchItem error." The root is
      // the only item at this stage.
      completionHandler(nil, NSFileProviderError(.noSuchItem))
    }
    return Progress()
  }

  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier,
    request: NSFileProviderRequest
  ) throws -> NSFileProviderEnumerator {
    switch containerItemIdentifier {
    case .rootContainer, .workingSet:
      return EmptyEnumerator()
    case .trashContainer:
      // NSFileProviderReplicatedExtension.h, enumeratorForContainerItemIdentifier,
      // "Error cases": "If containerItemIdentifier is
      // NSFileProviderTrashContainerItemIdentifier and the extension does not
      // support trashing items, then it should fail the call with the
      // NSFeatureUnsupportedError error code from the NSCocoaErrorDomain domain."
      throw CocoaError(.featureUnsupported)
    default:
      // Same section: an unknown container fails with
      // NSFileProviderErrorNoSuchItem.
      throw NSFileProviderError(.noSuchItem)
    }
  }

  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier,
    version requestedVersion: NSFileProviderItemVersion?,
    request: NSFileProviderRequest,
    completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    if itemIdentifier == .rootContainer {
      // The root is a folder and has no contents to fetch. Not noSuchItem,
      // which would make the system delete it; NSFileReadNoPermissionError is
      // the error the fetchContents "Error cases" (NSFileProviderReplicatedExtension.h)
      // name for content the user cannot read, and it is shown to the user.
      completionHandler(nil, nil, CocoaError(.fileReadNoPermission))
    } else {
      // Same section: "If the download fails because the item was deleted on
      // the server, the call should fail with the NSFileProviderErrorNoSuchItem
      // error." Nothing but the root exists at this stage.
      completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
    }
    return Progress()
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
    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    Self.logger.warning("Refused createItem: the File Provider is read-only")
    completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
    return Progress()
  }

  /// Returns a known item unchanged, so the system reverts the local edit. The
  /// root is the only item at this stage. For anything else, not noSuchItem:
  /// the modifyItem "Error cases" (NSFileProviderReplicatedExtension.h) say
  /// that makes "The system ... attempt to delete the item on disk". The same
  /// section lists NSFileProviderErrorCannotSynchronize for a modification that
  /// "cannot be applied because of the current state of the system / domain";
  /// the system then shows an error and backs off.
  func modifyItem(
    _ item: NSFileProviderItem,
    baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields,
    contents newContents: URL?,
    options: NSFileProviderModifyItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    Self.logger.warning("Refused modifyItem: the File Provider is read-only")
    if item.itemIdentifier == .rootContainer {
      completionHandler(RootItem(), [], false, nil)
    } else {
      completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
    }
    return Progress()
  }

  /// Rejects the deletion of the root; the deleteItem "Error cases"
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
    if identifier == .rootContainer {
      Self.logger.warning("Refused deleteItem: the File Provider is read-only")
      completionHandler(NSFileProviderError(.deletionRejected))
    } else {
      completionHandler(nil)
    }
    return Progress()
  }
}

/// The domain root: a read-only folder.
final class RootItem: NSObject, NSFileProviderItem {
  var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
  var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
  var filename: String { "Paperless" }
  var contentType: UTType { .folder }
  var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
  var fileSystemFlags: NSFileProviderFileSystemFlags { [.userReadable, .userExecutable] }
  /// Constant: the empty root never changes at this stage.
  var itemVersion: NSFileProviderItemVersion {
    NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8))
  }
}

/// Enumerates nothing: the root and the working set are empty at this stage.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
  /// Versioned, so the next stage can recognise an anchor handed out by this
  /// stub and answer it with `.syncAnchorExpired`, forcing a full enumeration.
  static let anchor = NSFileProviderSyncAnchor(Data("stub-v1".utf8))

  func invalidate() {}

  func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    observer.finishEnumerating(upTo: nil)
  }

  func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
    observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false)
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    completionHandler(Self.anchor)
  }
}
