//
//  LibraryItem.swift
//  FileProviderExtension
//

import DataModel
import FileProvider
import FileProviderCore
import Foundation
import UniformTypeIdentifiers

/// A folder or document of the library tree as a File Provider item.
///
/// Read-only: documents carry only `.allowsReading`, folders also
/// `.allowsContentEnumerating`, and no item is user-writable, so Files offers
/// no rename, move, delete or drop (upstream #727 Stage 4). A secondary
/// appearance (`tag:3/doc:12`) has its own identifier and parent but the same
/// name, versions, dates and content as the canonical `doc:12`.
final class LibraryItem: NSObject, NSFileProviderItem {
  let itemIdentifier: NSFileProviderItemIdentifier
  let parentItemIdentifier: NSFileProviderItemIdentifier
  let filename: String
  let contentType: UTType
  let capabilities: NSFileProviderItemCapabilities
  let fileSystemFlags: NSFileProviderFileSystemFlags
  let itemVersion: NSFileProviderItemVersion
  let documentSize: NSNumber?
  let creationDate: Date?
  let contentModificationDate: Date?

  init(_ item: TreeItem, document: Document?, size: Int64?) {
    itemIdentifier = item.identifier.fileProviderIdentifier
    parentItemIdentifier = item.parent.fileProviderIdentifier
    filename = item.name
    itemVersion = NSFileProviderItemVersion(
      contentVersion: Data(item.contentVersion.utf8),
      metadataVersion: Data(item.metadataVersion.utf8))
    if item.isFolder {
      contentType = .folder
      capabilities = [.allowsReading, .allowsContentEnumerating]
      // A folder needs the execute bit to be entered, as the root has.
      fileSystemFlags = [.userReadable, .userExecutable]
      documentSize = nil
      creationDate = nil
      contentModificationDate = nil
    } else {
      let ext = (item.name as NSString).pathExtension
      contentType = UTType(filenameExtension: ext) ?? .data
      capabilities = [.allowsReading]
      fileSystemFlags = [.userReadable]
      documentSize = size.map { NSNumber(value: $0) }
      creationDate = document?.created
      contentModificationDate = document?.modified
    }
  }
}

/// The domain root: a read-only folder. Its name is the domain's display
/// name; the filename here is not shown.
final class RootItem: NSObject, NSFileProviderItem {
  var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
  var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
  var filename: String { "Paperless" }
  var contentType: UTType { .folder }
  var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
  var fileSystemFlags: NSFileProviderFileSystemFlags { [.userReadable, .userExecutable] }
  /// Constant: the root itself never changes; its children report their own
  /// changes.
  var itemVersion: NSFileProviderItemVersion {
    NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8))
  }
}
