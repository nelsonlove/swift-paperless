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
/// (lines 396-400) asks for NSUserCancelledError. This map never makes
/// NSFileProviderErrorNoSuchItem, which makes the system delete the item
/// (line 371): a 404 is not proof a document is gone. It passes through one
/// a caller made itself (`item(for:)` and the enumerators answer it for an
/// identifier a library that was read does not hold); fetchContents rewrites
/// it at its own exit. The choice per kind of failure is FileProviderCore's
/// `ErrorAnswer`.
enum FileProviderErrors {
  static func map(_ error: any Error) -> NSError {
    let nsError = error as NSError
    if nsError.domain == NSFileProviderErrorDomain || nsError.domain == NSCocoaErrorDomain {
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

  /// The kind of `error`; FileProviderCore classifies all but the
  /// extension's own LibraryUnavailable.
  static func kind(of error: any Error) -> ErrorAnswer.Kind {
    error is LibraryUnavailable ? .libraryUnavailable : ErrorAnswer.Kind(classifying: error)
  }
}
