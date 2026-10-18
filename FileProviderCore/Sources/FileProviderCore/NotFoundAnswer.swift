//
//  NotFoundAnswer.swift
//  FileProviderCore
//

/// What `fetchContents` answers when the server says 404.
///
/// Only the document download's own 404 can mean the document is gone, and
/// only when the database, read again, no longer holds it: then
/// NSFileProviderErrorNoSuchItem, which makes the system delete the item
/// (NSFileProviderReplicatedExtension.h, fetchContents "Error cases", line
/// 371). A 404 from anything else (building the repository probes the
/// server's versions) or for a document the database still holds is "the
/// current state of the system / domain" (line 382):
/// NSFileProviderErrorServerUnreachable, so the system keeps the item.
public enum NotFoundAnswer: Equatable, Sendable {
  case noSuchItem
  case serverUnreachable

  /// Where the 404 came from.
  public enum Source: Equatable, Sendable {
    /// The download of the document's file.
    case documentDownload
    /// Any other request (building the repository, a version probe).
    case other
  }

  /// - Parameter documentInDatabase: whether the database, read after the
  ///   404, holds the document; `nil` when it could not be read.
  public static func answer(source: Source, documentInDatabase: Bool?) -> NotFoundAnswer {
    source == .documentDownload && documentInDatabase == false ? .noSuchItem : .serverUnreachable
  }
}
