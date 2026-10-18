//
//  TemporaryDownloadSweepTest.swift
//  Networking
//

import Foundation
import Testing

@testable import Networking

@Suite
struct TemporaryDownloadSweepTest {
  private func folder(_ name: String, in directory: URL, age: TimeInterval, now: Date) throws
    -> URL
  {
    let url = directory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("made-up".utf8).write(to: url.appendingPathComponent("document.pdf"))
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    return url
  }

  @Test("Only download folders older than the age are removed")
  func removesStaleDownloadFolders() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let day: TimeInterval = 24 * 60 * 60

    let stale = try folder(UUID().uuidString, in: directory, age: 2 * day, now: now)
    let young = try folder(UUID().uuidString, in: directory, age: 60, now: now)
    let other = try folder("not-a-download", in: directory, age: 2 * day, now: now)
    let file = directory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-2 * day)], ofItemAtPath: file.path)

    let removed = ApiRepository.sweepTemporaryDownloads(olderThan: day, in: directory, now: now)
    #expect(removed == 1)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: young.path))
    #expect(FileManager.default.fileExists(atPath: other.path))
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test("Downloads live in a folder of their own, which is what the sweep walks")
  func dedicatedFolder() {
    let downloads = ApiRepository.temporaryDownloadsDirectory
    #expect(downloads.lastPathComponent == "paperless-downloads")
    #expect(
      downloads.deletingLastPathComponent().standardizedFileURL.path
        == URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path)
  }
}
