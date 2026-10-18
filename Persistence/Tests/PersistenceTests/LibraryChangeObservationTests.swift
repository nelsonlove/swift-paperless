import DataModel
import Foundation
import Testing

@testable import Persistence

@Suite("LibraryChangeObservation")
struct LibraryChangeObservationTests {
  private func doc(_ id: UInt) -> Document {
    Document(
      id: id, title: "Doc \(id)", asn: nil, created: Date(timeIntervalSince1970: 1000), tags: [],
      owner: .user(1))
  }

  /// Whether the stream yields within `seconds`. Use once per stream: an
  /// abandoned wait ends the stream.
  private func yields(_ stream: AsyncStream<Void>, within seconds: Double = 3) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() != nil
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(seconds))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
  }

  @Test("A document write is reported")
  func documentWrite() async throws {
    let server = UUID()
    let database = try Database.seeded(serverID: server)
    let changes = database.observeLibraryChanges()

    try await database.upsertDocuments([doc(1)], serverID: server)

    #expect(await yields(changes))
  }

  @Test("An element write is reported")
  func elementWrite() async throws {
    let server = UUID()
    let database = try Database.seeded(serverID: server)
    let changes = database.observeLibraryChanges()

    try await database.replaceElements(
      [
        Correspondent(
          id: 5, documentCount: 0, lastCorrespondence: nil, name: "Acme Utilities",
          slug: "acme", matchingAlgorithm: .literal, match: "", isInsensitive: false)
      ], of: CorrespondentRecord.self, serverID: server)

    #expect(await yields(changes))
  }

  @Test("A write outside the library tables is not reported")
  func unrelatedWrite() async throws {
    let server = UUID()
    let database = try Database.seeded(serverID: server)
    let changes = database.observeLibraryChanges()

    try await database.setLastRefreshedAt(Date(), serverID: server)
    #expect(await !yields(changes, within: 0.3))
  }

  @Test("An in-memory database says so")
  func inMemoryIsNotOnDisk() throws {
    #expect(try Database.inMemory().isOnDisk == false)
  }
}
