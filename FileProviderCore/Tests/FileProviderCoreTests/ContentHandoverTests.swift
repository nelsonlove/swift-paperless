//
//  ContentHandoverTests.swift
//  FileProviderCore
//

import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct ContentHandoverTests {
  private func scratch() throws -> (source: URL, destination: URL, folder: URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("handover-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("source.pdf")
    try Data("made-up content".utf8).write(to: source)
    return (source, folder.appendingPathComponent("handed.pdf"), folder)
  }

  @Test("A clone is the first choice")
  func clones() throws {
    let (source, destination, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let method = try ContentHandover.place(source, at: destination)
    // The host's temporary directory is APFS on macOS.
    #expect(method == .clone)
    #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
  }

  @Test(
    "A clone that fails across volumes, unsupported or refused falls back to a copy",
    arguments: [EXDEV, ENOTSUP, EPERM])
  func fallsBack(_ errorCode: Int32) throws {
    let (source, destination, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let method = try ContentHandover.place(source, at: destination, clone: { _, _ in errorCode })
    #expect(method == .copy)
    #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
  }

  @Test("Any other clone error is the answer")
  func otherErrorThrows() throws {
    let (source, destination, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(throws: POSIXError.self) {
      try ContentHandover.place(source, at: destination, clone: { _, _ in ENOENT })
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("A failed copy leaves nothing behind")
  func failedCopyThrows() throws {
    let (source, destination, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.removeItem(at: source)
    #expect(throws: (any Error).self) {
      try ContentHandover.place(source, at: destination, clone: { _, _ in EXDEV })
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }
}

@Suite
struct NotFoundAnswerTests {
  @Test("Only the download's own 404, for a document gone from the database, is noSuchItem")
  func answers() {
    #expect(
      NotFoundAnswer.answer(source: .documentDownload, documentInDatabase: false) == .noSuchItem)
    #expect(
      NotFoundAnswer.answer(source: .documentDownload, documentInDatabase: true)
        == .serverUnreachable)
    #expect(
      NotFoundAnswer.answer(source: .documentDownload, documentInDatabase: nil)
        == .serverUnreachable)
    // A 404 from building the repository (the version probe) never deletes.
    #expect(NotFoundAnswer.answer(source: .other, documentInDatabase: false) == .serverUnreachable)
  }
}
