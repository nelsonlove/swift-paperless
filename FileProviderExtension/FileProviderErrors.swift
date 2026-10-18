//
//  FileProviderErrors.swift
//  FileProviderExtension
//

import Common
import FileProvider
import Foundation
import Networking

/// Maps an error to one the File Provider system accepts.
///
/// NSFileProviderReplicatedExtension.h, fetchContents "Error cases" (lines
/// 369-394 in the iOS 26.5 SDK): errors "must be in one of the following
/// domains: NSCocoaErrorDomain, NSFileProviderErrorDomain"; one that fits
/// neither is an NSCocoaErrorDomain NSXPCConnectionReplyInvalid with the
/// original under NSUnderlyingErrorKey. The same section names
/// NSFileProviderErrorNoSuchItem for an item deleted on the server,
/// NSFileReadNoPermissionError for content the user may not read, and
/// NSFileProviderErrorNotAuthenticated and NSFileProviderErrorServerUnreachable
/// for "the current state of the system / domain"; the Cancellations section
/// (lines 396-400) asks for NSUserCancelledError.
enum FileProviderErrors {
  static func map(_ error: any Error) -> NSError {
    let nsError = error as NSError
    if nsError.domain == NSFileProviderErrorDomain || nsError.domain == NSCocoaErrorDomain {
      return nsError
    }
    if error is LibraryUnavailable {
      // The library cannot be read: "the current state of the system /
      // domain" (each method's "Error cases"), so the system backs off and
      // keeps its items. Never noSuchItem.
      return NSFileProviderError(.serverUnreachable) as NSError
    }
    if error.isCancellationError {
      return CocoaError(.userCancelled) as NSError
    }
    if let request = error as? RequestError {
      switch request {
      case .unauthorized:
        return NSFileProviderError(.notAuthenticated) as NSError
      case .forbidden:
        return CocoaError(.fileReadNoPermission) as NSError
      case .unexpectedStatusCode(let code, _) where code == .notFound:
        return NSFileProviderError(.noSuchItem) as NSError
      case .connectivity, .localNetworkDenied, .certificate:
        return NSFileProviderError(.serverUnreachable) as NSError
      default:
        break
      }
    }
    return NSError(
      domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid,
      userInfo: [NSUnderlyingErrorKey: nsError])
  }
}
