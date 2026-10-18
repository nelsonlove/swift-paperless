//
//  FileProviderSettingsTests.swift
//  FileProviderCore
//

import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct FileProviderSettingsTests {
  @Test("Defaults: correspondent layout, all browse folders, archive")
  func defaults() {
    let settings = FileProviderSettings()
    #expect(settings.layout == .correspondent)
    #expect(settings.browseFolders == [.tag, .correspondent, .documentType])
    #expect(settings.content == .archive)
  }

  @Test("Settings survive a JSON round trip with stable bytes")
  func roundTrip() throws {
    let settings = FileProviderSettings(
      layout: .correspondentYear, browseFolders: [.documentType, .tag], content: .original)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(settings)
    #expect(
      String(decoding: data, as: UTF8.self)
        == #"{"browseFolders":["tag","type"],"content":"original","layout":"correspondentYear"}"#)
    #expect(try JSONDecoder().decode(FileProviderSettings.self, from: data) == settings)
  }

  @Test("Unknown or missing values fall back to the defaults")
  func lenientDecoding() throws {
    let json = #"{"layout":"storagePath","browseFolders":["tag","shelf"],"content":7}"#
    let settings = try JSONDecoder().decode(FileProviderSettings.self, from: Data(json.utf8))
    #expect(settings.layout == .correspondent)
    #expect(settings.browseFolders == [.tag])
    #expect(settings.content == .archive)

    let empty = try JSONDecoder().decode(FileProviderSettings.self, from: Data("{}".utf8))
    #expect(empty == FileProviderSettings())
  }

  @Test(
    "A value that is not an object decodes as the default",
    arguments: ["null", "[]", "[1,2]", "\"correspondent\"", "42", "true"])
  func nonObject(_ json: String) throws {
    let settings = try JSONDecoder().decode(FileProviderSettings.self, from: Data(json.utf8))
    #expect(settings == .default)
    #expect(FileProviderSettings.decode(from: Data(json.utf8)) == .default)
  }

  @Test("decode(from:) never throws, even for bytes that are not JSON")
  func decodeNeverThrows() throws {
    #expect(FileProviderSettings.decode(from: Data("not json".utf8)) == .default)
    #expect(FileProviderSettings.decode(from: Data()) == .default)
    let stored = FileProviderSettings(layout: .year, browseFolders: [], content: .original)
    let data = try JSONEncoder().encode(stored)
    #expect(FileProviderSettings.decode(from: data) == stored)
  }

  @Test("Browse folders decode per element; only a missing or non-array value is the default")
  func browseFoldersPerElement() throws {
    func decode(_ json: String) throws -> Set<BrowseFolder> {
      try JSONDecoder().decode(FileProviderSettings.self, from: Data(json.utf8)).browseFolders
    }
    #expect(
      try decode(#"{"browseFolders":["tag",3,null,{"x":1},"shelf","type"]}"#) == [
        .tag, .documentType,
      ])
    #expect(try decode(#"{"browseFolders":[]}"#) == [])
    #expect(try decode(#"{"browseFolders":[1,2]}"#) == [])
    #expect(try decode(#"{"browseFolders":"tag"}"#) == Set(BrowseFolder.allCases))
    #expect(try decode(#"{"browseFolders":null}"#) == Set(BrowseFolder.allCases))
    #expect(try decode(#"{}"#) == Set(BrowseFolder.allCases))
  }
}
