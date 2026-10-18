//
//  ContentHandover.swift
//  FileProviderCore
//

import Foundation

/// Puts a file where `fetchContents` hands it to the system: an APFS clone
/// when the volume allows one, else a copy.
///
/// "The system clones and unlinks the received fileContents ... If the
/// extension wishes to keep a copy of the content, it must provide a clone of
/// the that content" (NSFileProviderReplicatedExtension.h, fetchContents,
/// "File ownership", lines 343-349 in the iOS 26.5 SDK). The content store
/// keeps its own file, so a clone is the first choice. A clone fails when the
/// source is on another volume (EXDEV), the file system cannot clone
/// (ENOTSUP), or the sandbox refuses it (EPERM); the file is then copied, so
/// the open still succeeds.
public enum ContentHandover {
  /// How the file reached the destination.
  public enum Method: String, Equatable, Sendable {
    /// clonefile(2).
    case clone
    /// `FileManager.copyItem`.
    case copy
  }

  /// The clonefile(2) errors after which the file is copied; any other error
  /// (a missing source, a full disk) is the answer.
  public static let fallbackErrors: Set<Int32> = [EXDEV, ENOTSUP, EPERM]

  /// Clones `source` to `destination`, or copies it when the clone fails with
  /// one of ``fallbackErrors``.
  ///
  /// - Parameter clone: clonefile(2), returning 0 or an errno; tests pass one
  ///   that fails.
  /// - Returns: how the file was placed.
  /// - Throws: a `POSIXError` when the clone fails with another error, or the
  ///   copy's error.
  @discardableResult
  public static func place(
    _ source: URL, at destination: URL,
    clone: (String, String) -> Int32 = ContentHandover.clonefile
  ) throws -> Method {
    let cloneResult = clone(source.path, destination.path)
    if cloneResult == 0 { return .clone }
    guard fallbackErrors.contains(cloneResult) else {
      throw POSIXError(POSIXErrorCode(rawValue: cloneResult) ?? .EIO)
    }
    try? FileManager.default.removeItem(at: destination)
    do {
      try FileManager.default.copyItem(at: source, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    return .copy
  }

  /// clonefile(2): 0, or the errno it set.
  public static func clonefile(_ source: String, _ destination: String) -> Int32 {
    Darwin.clonefile(source, destination, 0) == 0 ? 0 : errno
  }
}
