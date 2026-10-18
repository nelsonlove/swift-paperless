//
//  FetchFailureAnswer.swift
//  FileProviderCore
//

import Common
import Networking

/// What `fetchContents` does when getting a document's content fails, before
/// the error map (`ErrorAnswer`) decides the rest.
///
/// The rule:
/// - a cancellation is NSUserCancelledError (fetchContents, "Cancellations");
/// - a 403 is NSFileReadNoPermissionError, which the fetchContents "Error
///   cases" name for content the user may not read, even when a stored copy
///   exists: the server has withdrawn access;
/// - any other failure (a 404 from the server or anything between, a 401,
///   connectivity and timeouts, a 5xx, a certificate or local-network
///   refusal, a local read that failed) serves the stored copy when there is
///   one, possibly outdated;
/// - without a stored copy the error is rethrown, and `ErrorAnswer` maps it.
///
/// No answer here or in `ErrorAnswer` is NSFileProviderErrorNoSuchItem, which
/// makes the system delete the item (NSFileProviderReplicatedExtension.h,
/// fetchContents "Error cases"). A 404 never proves a document is gone; a
/// deleted document leaves Files only through the working-set change diff,
/// after the app's sync removes its row from the database.
public enum FetchFailureAnswer<Copy: Sendable>: Sendable {
  case storedCopy(Copy)
  case cancelled
  case noPermission
  case rethrow

  public static func answer(for kind: ErrorAnswer.Kind, storedCopy: Copy?) -> Self {
    switch kind {
    case .cancelled: .cancelled
    case .forbidden: .noPermission
    default: storedCopy.map { .storedCopy($0) } ?? .rethrow
    }
  }
}

extension FetchFailureAnswer: Equatable where Copy: Equatable {}

/// The pure part of the extension's error map (`FileProviderErrors.map`): the
/// File Provider error for each kind of failure. No kind maps to
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

  public enum Kind: Equatable, Sendable {
    case libraryUnavailable
    case cancelled
    case unauthorized
    case forbidden
    case notFound
    case unreachable
    case other

    /// The kind of `error` as the networking layer reports it: a status
    /// code as `RequestError` (a 404 as `unexpectedStatusCode`), a transport
    /// failure as `RequestError.connectivity` once
    /// `RequestError.normalizingTransportFailure` has seen it. The extension
    /// recognises its own `libraryUnavailable` before calling this.
    public init(classifying error: any Error) {
      if error.isCancellationError {
        self = .cancelled
        return
      }
      guard let request = error as? RequestError else {
        self = .other
        return
      }
      switch request {
      case .unauthorized: self = .unauthorized
      case .forbidden: self = .forbidden
      case .unexpectedStatusCode(let code, _) where code == .notFound: self = .notFound
      case .connectivity, .localNetworkDenied, .certificate: self = .unreachable
      default: self = .other
      }
    }
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
