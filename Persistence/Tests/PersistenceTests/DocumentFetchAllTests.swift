import DataModel
import Foundation
import Testing

@testable import Persistence

@Suite("DocumentFetchAll")
struct DocumentFetchAllTests {
  private func doc(_ id: UInt, _ title: String) -> Document {
    Document(
      id: id, title: title, asn: nil, created: Date(timeIntervalSince1970: 1000), tags: [],
      owner: .user(1))
  }

  private func ids(_ docs: [Document]) -> [UInt] { docs.map(\.id) }

  @Test("an empty server yields no documents")
  func emptyServer() async throws {
    let server = UUID()
    let database = try Database.seeded(serverID: server)
    #expect(try await database.documents(serverID: server).isEmpty)
    #expect(try await database.documents(serverID: server, after: nil, limit: 10).isEmpty)
  }

  @Test("documents of two servers stay apart")
  func serversKeptApart() async throws {
    let server = UUID()
    let other = UUID()
    let database = try Database.seeded(serverID: server)
    try database.upsertConnection(
      ConnectionRecord(
        id: other,
        url: URL(string: "https://other.example.com/api/")!,
        user: .init(id: 1, isSuperUser: true, username: "other")))
    try await database.upsertDocuments([doc(1, "A"), doc(2, "B")], serverID: server)
    try await database.upsertDocuments([doc(2, "X"), doc(7, "Y")], serverID: other)

    let mine = try await database.documents(serverID: server)
    let theirs = try await database.documents(serverID: other)
    #expect(ids(mine) == [1, 2])
    #expect(ids(theirs) == [2, 7])
    #expect(mine.map(\.title) == ["A", "B"])
    #expect(theirs.map(\.title) == ["X", "Y"])
    #expect(try await database.documents(serverID: other, after: nil, limit: 10).count == 2)
  }

  @Test("documents decode like document(serverID:id:)")
  func decodeRoundTrip() async throws {
    let server = UUID()
    let database = try Database.seeded(serverID: server)
    var input = Document(
      id: 3, title: "Invoice", asn: 42, documentType: 2, correspondent: 3,
      created: Date(timeIntervalSince1970: 1000), tags: [4, 5],
      added: Date(timeIntervalSince1970: 2000), modified: Date(timeIntervalSince1970: 3000),
      originalFileName: "scan.pdf", archivedFileName: "archive.pdf",
      storagePath: 6, owner: .user(7), pageCount: 3)
    input.permissions = Permissions { $0.view = .init(users: [1, 2]) }
    try await database.upsertDocuments([input, doc(1, "A")], serverID: server)

    let all = try await database.documents(serverID: server)
    #expect(ids(all) == [1, 3])
    #expect(all.last == input)
    #expect(all.last == (try await database.document(serverID: server, id: 3)))
  }

  @Test("paging by id: start, middle, past the end, limit smaller than count")
  func paging() async throws {
    let server = UUID()
    let database = try Database.seeded(serverID: server)
    // Inserted out of order; the page order is by id.
    try await database.upsertDocuments(
      [doc(5, "E"), doc(1, "A"), doc(9, "I"), doc(3, "C"), doc(7, "G")], serverID: server)

    #expect(ids(try await database.documents(serverID: server, after: nil, limit: 2)) == [1, 3])
    #expect(ids(try await database.documents(serverID: server, after: 3, limit: 2)) == [5, 7])
    // `after` is exclusive and need not be a cached id.
    #expect(ids(try await database.documents(serverID: server, after: 4, limit: 10)) == [5, 7, 9])
    #expect(ids(try await database.documents(serverID: server, after: 9, limit: 10)).isEmpty)
    #expect(ids(try await database.documents(serverID: server, after: nil, limit: 10)) == [1, 3, 5, 7, 9])
    #expect(ids(try await database.documents(serverID: server, after: nil, limit: 0)).isEmpty)
    #expect(ids(try await database.documents(serverID: server)) == [1, 3, 5, 7, 9])
  }
}
