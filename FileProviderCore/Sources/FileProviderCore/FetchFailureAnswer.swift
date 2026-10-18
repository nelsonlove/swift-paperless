//
//  FetchFailureAnswer.swift
//  FileProviderCore
//

/// What `fetchContents` answers when getting a document's content fails.
///
/// NSFileProviderErrorNoSuchItem makes the system delete the item
/// (NSFileProviderReplicatedExtension.h, fetchContents "Error cases": "the
/// system will consider the item has been removed from the domain and will
/// attempt to delete it from disk"). A failed download never shows that the
/// document is gone: a proxy, a misrouted request or a deleted version answer
/// 404 too. So `fetchContents` never answers it, and there is no such case
/// here. A deleted document leaves Files only through the working-set change
/// diff, after the app's sync removes its row from the database.
public enum FetchFailureAnswer: Equatable, Sendable {
  /// Serve the stored copy, possibly outdated.
  case storedCopy
  /// NSFileProviderErrorServerUnreachable: "the current state of the system /
  /// domain"; the system keeps the item and backs off until it is signalled.
  case serverUnreachable
  /// NSUserCancelledError (fetchContents, "Cancellations").
  case cancelled
  /// The failure's own error, through `ErrorAnswer` (never a deletion).
  case error

  public enum Failure: Equatable, Sendable {
    /// The server, or anything between, answered 404.
    case notFound
    /// Any other failure (403, unreachable, a login or certificate refused,
    /// a local read that failed).
    case other
  }

  public static func answer(for failure: Failure, hasStoredCopy: Bool, isCancelled: Bool)
    -> FetchFailureAnswer
  {
    if isCancelled { return .cancelled }
    if hasStoredCopy { return .storedCopy }
    return failure == .notFound ? .serverUnreachable : .error
  }
}

/// The pure part of the extension's error map (`FileProviderErrors.map`): the
/// File Provider error for each kind of failure. No kind maps to
/// NSFileProviderErrorNoSuchItem, which makes the system delete the item.
public enum ErrorAnswer: Equatable, Sendable {
  /// NSFileProviderErrorServerUnreachable.
  case serverUnreachable
  /// NSFileProviderErrorNotAuthenticated.
  case notAuthenticated
  /// NSCocoaErrorDomain NSFileReadNoPermissionError.
  case noPermission
  /// NSCocoaErrorDomain NSUserCancelledError.
  case cancelled
  /// NSCocoaErrorDomain NSXPCConnectionReplyInvalid with the original error
  /// under NSUnderlyingErrorKey: a transient error, retried.
  case unrepresentable

  public enum Kind: Equatable, Sendable {
    case libraryUnavailable
    case cancelled
    case unauthorized
    case forbidden
    case notFound
    case unreachable
    case other
  }

  public static func answer(for kind: Kind) -> ErrorAnswer {
    switch kind {
    case .libraryUnavailable, .notFound, .unreachable: .serverUnreachable
    case .cancelled: .cancelled
    case .unauthorized: .notAuthenticated
    case .forbidden: .noPermission
    case .other: .unrepresentable
    }
  }
}
