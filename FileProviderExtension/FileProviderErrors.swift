//
//  FileProviderErrors.swift
//  FileProviderExtension
//

import Common
import FileProvider
import FileProviderCore
import Foundation
import Networking

/// Maps an error to one the File Provider system accepts.
///
/// NSFileProviderReplicatedExtension.h, fetchContents "Error cases" (lines
/// 369-394 in the iOS 26.5 SDK): errors "must be in one of the following
/// domains: NSCocoaErrorDomain, NSFileProviderErrorDomain"; one that fits
/// neither is an NSCocoaErrorDomain NSXPCConnectionReplyInvalid with the
/// original under NSUnderlyingErrorKey. The same section names
/// NSFileReadNoPermissionError for content the user may not read, and
/// NSFileProviderErrorNotAuthenticated and NSFileProviderErrorServerUnreachable
/// for "the current state of the system / domain"; the Cancellations section
/// (lines 396-400) asks for NSUserCancelledError. This map never gives
/// NSFileProviderErrorNoSuchItem, which makes the system delete the item
/// (line 371): a 404 is not proof a document is gone, and deletions reach
/// Files only through the working-set change diff over the database. The
/// choice per kind of failure is FileProviderCore's `ErrorAnswer`.
enum FileProviderErrors {
  static func map(_ error: any Error) -> NSError {
    let nsError = error as NSError
    if nsError.domain == NSFileProviderErrorDomain {
      // Passed through, except a deletion: no error that reaches this map
      // shows that an item is gone.
      return nsError.code == NSFileProviderError.Code.noSuchItem.rawValue
        ? NSFileProviderError(.serverUnreachable) as NSError : nsError
    }
    if nsError.domain == NSCocoaErrorDomain {
      return nsError
    }
    switch ErrorAnswer.answer(for: kind(of: error)) {
    case .serverUnreachable:
      return NSFileProviderError(.serverUnreachable) as NSError
    case .notAuthenticated:
      return NSFileProviderError(.notAuthenticated) as NSError
    case .noPermission:
      return CocoaError(.fileReadNoPermission) as NSError
    case .cancelled:
      return CocoaError(.userCancelled) as NSError
    case .unrepresentable:
      return NSError(
        domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid,
        userInfo: [NSUnderlyingErrorKey: nsError])
    }
  }

  private static func kind(of error: any Error) -> ErrorAnswer.Kind {
    if error is LibraryUnavailable { return .libraryUnavailable }
    if error.isCancellationError { return .cancelled }
    guard let request = error as? RequestError else { return .other }
    switch request {
    case .unauthorized: return .unauthorized
    case .forbidden: return .forbidden
    case .unexpectedStatusCode(let code, _) where code == .notFound: return .notFound
    case .connectivity, .localNetworkDenied, .certificate: return .unreachable
    default: return .other
    }
  }
}
