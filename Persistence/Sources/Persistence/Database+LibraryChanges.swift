import Foundation
import GRDB
import os

extension Database {
  /// The tables a document browser's tree is built from: the documents and
  /// the elements that name and group them.
  static let libraryTables = [
    DocumentRecord.databaseTableName,
    TagRecord.databaseTableName,
    CorrespondentRecord.databaseTableName,
    DocumentTypeRecord.databaseTableName,
    StoragePathRecord.databaseTableName,
  ]

  /// Yields once after every committed transaction in this process that wrote
  /// to a document or element table, for every server alike: the region does
  /// not say which rows changed. Bursts are not coalesced here, beyond a
  /// buffer of one; ending the consuming task stops the observation.
  ///
  /// Only this connection's own writes are seen, not another process's.
  public func observeLibraryChanges() -> AsyncStream<Void> {
    let writer = writer
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let observation = DatabaseRegionObservation(
        tracking: Self.libraryTables.map { Table($0) as any DatabaseRegionConvertible })
      let cancellable = observation.start(
        in: writer,
        onError: { error in
          Logger.persistence.error("Library change observation failed: \(error)")
          continuation.finish()
        },
        onChange: { _ in continuation.yield() })
      continuation.onTermination = { _ in cancellable.cancel() }
    }
  }
}
