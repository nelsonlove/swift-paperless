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
    #expect(method == .copyfile)
    #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
  }

  @Test("When copyfile fails too, FileManager copies")
  func lastResort() throws {
    let (source, destination, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let method = try ContentHandover.place(
      source, at: destination, clone: { _, _ in EXDEV }, copyFile: { _, _ in EIO })
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
}
