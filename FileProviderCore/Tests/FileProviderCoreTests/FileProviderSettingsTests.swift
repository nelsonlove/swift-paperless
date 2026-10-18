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
}
