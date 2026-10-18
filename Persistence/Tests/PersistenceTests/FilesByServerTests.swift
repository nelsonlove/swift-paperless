import Common
import Foundation
import Testing

@testable import Persistence

@Suite
struct FilesByServerTests {
  @Test("files(serverID:) returns only that server's rows")
  func filtersByServer() async throws {
    let first = UUID()
    let second = UUID()
    let database = try Database.seeded(serverID: first, documents: [FileFixtures.doc(1)])
    try FileFixtures.addServer(second, to: database)
    let now = FileFixtures.date(2000)
    try await FileFixtures.record(database, FileFixtures.key(first, 1), size: 10, accessed: now)
    try await FileFixtures.record(
      database, FileFixtures.key(first, 1, .thumbnail), size: 2, accessed: now)
    try await FileFixtures.record(database, FileFixtures.key(second, 7), size: 30, accessed: now)

    let rows = try await database.files(serverID: first)
    #expect(
      Set(rows.compactMap(\.key)) == [
        FileFixtures.key(first, 1), FileFixtures.key(first, 1, .thumbnail),
      ])
    #expect(try await database.files(serverID: UUID()).isEmpty)
  }
}
