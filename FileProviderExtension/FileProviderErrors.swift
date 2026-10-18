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
/// (lines 396-400) asks for NSUserCancelledError. The failure is classified
/// once (`kind(of:)`) and answered from FileProviderCore's `ErrorAnswer`
/// table. With `inFetch`, the answer is never NSFileProviderErrorNoSuchItem,
/// which makes the system delete the item (line 371): a 404 is not proof a
/// document is gone. Other callers' noSuchItem (`item(for:)` and the
/// enumerators answer it for an identifier a library that was read does not
/// hold) passes through.
enum FileProviderErrors {
  static func map(_ error: any Error, inFetch: Bool = false) -> NSError {
    switch ErrorAnswer.answer(for: kind(of: error), inFetch: inFetch) {
    case .passThrough:
      return error as NSError
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
        userInfo: [NSUnderlyingErrorKey: error as NSError])
    }
  }

  /// The kind of `error`, the one place a failure is classified.
  static func kind(of error: any Error) -> ErrorAnswer.Kind {
    let nsError = error as NSError
    if nsError.domain == NSFileProviderErrorDomain {
      return nsError.code == NSFileProviderError.Code.noSuchItem.rawValue
        ? .noSuchItem : .systemError
    }
    if nsError.domain == NSCocoaErrorDomain { return .systemError }
    if error is LibraryUnavailable { return .libraryUnavailable }
    if error is DocumentNotInLibrary { return .documentNotInLibrary }
    if error.isCancellationError { return .cancelled }
    guard let request = error as? RequestError else { return .other }
    switch request {
    case .unauthorized: return .unauthorized
    case .forbidden: return .forbidden
    case .unexpectedStatusCode(let code, _): return ErrorAnswer.Kind(httpStatus: code.rawValue)
    case .connectivity, .localNetworkDenied, .certificate: return .unreachable
    default: return .other
    }
  }
}
