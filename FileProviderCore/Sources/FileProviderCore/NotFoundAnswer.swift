//
//  NotFoundAnswer.swift
//  FileProviderCore
//

/// What `fetchContents` answers when the download of a document's file gets a
/// 404. (A 404 from any other request, such as the version probe while the
/// repository is built, never comes here: it is the state of the server, not
/// of the document.)
///
/// NSFileProviderErrorNoSuchItem makes the system delete the item
/// (NSFileProviderReplicatedExtension.h, fetchContents "Error cases", line
/// 371), so it is the answer only when the document is gone: the database no
/// longer holds it, or the server, asked for the document itself (a read, no
/// write), answers 404 too. Anything else is "the current state of the system
/// / domain" (line 382), NSFileProviderErrorServerUnreachable, so the system
/// keeps the item; when the server still has the document but under another
/// current version, the local row is out of date, and the extension also
/// signals so the next sync can bring it up to date.
public enum NotFoundAnswer: Equatable, Sendable {
  case noSuchItem
  /// NSFileProviderErrorServerUnreachable; `signal` asks for a signal of the
  /// working set as well.
  case serverUnreachable(signal: Bool)

  /// What the server says about the document itself after the download 404.
  public enum ServerDocument: Equatable, Sendable {
    /// The document request answered 404 too.
    case gone
    /// The server has the document with this current version id.
    case present(currentVersionID: UInt)
    /// The server could not be asked, or did not answer.
    case unknown
  }

  /// - Parameters:
  ///   - inDatabase: whether the database, read after the 404, still holds
  ///     the document (a read that failed counts as holding it).
  ///   - server: what the server says about the document; `nil` when it was
  ///     not asked (the database already settled it).
  ///   - localVersionID: the current version id of the local row.
  public static func answer(
    inDatabase: Bool, server: ServerDocument?, localVersionID: UInt
  ) -> NotFoundAnswer {
    guard inDatabase else { return .noSuchItem }
    switch server {
    case .gone:
      return .noSuchItem
    case .present(let currentVersionID) where currentVersionID != localVersionID:
      return .serverUnreachable(signal: true)
    case .present, .unknown, nil:
      return .serverUnreachable(signal: false)
    }
  }
}
