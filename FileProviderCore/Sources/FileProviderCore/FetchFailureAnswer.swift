//
//  FetchFailureAnswer.swift
//  FileProviderCore
//

import Foundation

/// What `fetchContents` does when a step of getting a document's content
/// fails, before the error map (`ErrorAnswer`) decides the rest.
///
/// The rule:
/// - a cancellation is NSUserCancelledError (fetchContents, "Cancellations");
/// - a 403 from the document's own download is NSFileReadNoPermissionError,
///   which the fetchContents "Error cases" name for content the user may not
///   read, even when a stored copy exists: the server has withdrawn access;
/// - any other failure serves the stored copy when there is one, possibly
///   outdated: a 404, a 401, connectivity and timeouts, a 5xx, a certificate
///   or local-network refusal, a local read that failed, and a 403 from
///   building the repository (the version probe), which says nothing about
///   the document;
/// - without a stored copy the error goes to `ErrorAnswer`.
///
/// No answer here, and none `ErrorAnswer` gives for a fetch, is
/// NSFileProviderErrorNoSuchItem, which makes the system delete the item
/// (NSFileProviderReplicatedExtension.h, fetchContents "Error cases"). A 404
/// never proves a document is gone; a deleted document leaves Files only
/// through the working-set change diff, after the app's sync removes its row.
public enum FetchFailureAnswer: Equatable, Sendable {
  case storedCopy(URL)
  case cancelled
  case noPermission
  case mapError

  /// The step of the fetch that failed.
  public enum Step: Equatable, Sendable {
    /// Reading the server row from the database.
    case serverRow
    /// Building the server's repository (it may probe the server's versions).
    case repository
    /// The document's own download.
    case download
  }

  public static func answer(for kind: ErrorAnswer.Kind, in step: Step, storedCopy: URL?)
    -> FetchFailureAnswer
  {
    switch kind {
    case .cancelled: return .cancelled
    case .forbidden where step == .download: return .noPermission
    default: return storedCopy.map { .storedCopy($0) } ?? .mapError
    }
  }
}

/// The pure part of the extension's error map (`FileProviderErrors.map`): the
/// error to answer for each kind of failure. For a fetch, no kind answers
/// NSFileProviderErrorNoSuchItem.
public enum ErrorAnswer: Equatable, Sendable {
  /// NSFileProviderErrorServerUnreachable: "the current state of the system /
  /// domain"; the system keeps the item and backs off until it is signalled.
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
  /// The error as it is: already in NSFileProviderErrorDomain or
  /// NSCocoaErrorDomain.
  case passThrough

  /// A failure as the extension classifies it (`FileProviderErrors.kind`).
  public enum Kind: Equatable, Sendable {
    /// The library cannot be read.
    case libraryUnavailable
    /// The library was read and does not hold the document.
    case documentNotInLibrary
    case cancelled
    /// HTTP 401.
    case unauthorized
    /// HTTP 403.
    case forbidden
    /// HTTP 404, from the server or anything between.
    case notFound
    /// No response: offline, timed out, a certificate or local-network
    /// refusal.
    case unreachable
    /// NSFileProviderErrorNoSuchItem, made by a caller.
    case noSuchItem
    /// Any other error already in NSFileProviderErrorDomain or
    /// NSCocoaErrorDomain.
    case systemError
    case other

    /// The kind of an HTTP status the server answered with.
    public init(httpStatus: Int) {
      switch httpStatus {
      case 401: self = .unauthorized
      case 403: self = .forbidden
      case 404: self = .notFound
      default: self = .other
      }
    }
  }

  /// - Parameter inFetch: whether the answer is fetchContents's, which never
  ///   answers NSFileProviderErrorNoSuchItem; other callers' noSuchItem
  ///   passes through.
  public static func answer(for kind: Kind, inFetch: Bool) -> ErrorAnswer {
    switch kind {
    case .libraryUnavailable, .documentNotInLibrary, .notFound, .unreachable:
      .serverUnreachable
    case .noSuchItem: inFetch ? .serverUnreachable : .passThrough
    case .systemError: .passThrough
    case .cancelled: .cancelled
    case .unauthorized: .notAuthenticated
    case .forbidden: .noPermission
    case .other: .unrepresentable
    }
  }
}
