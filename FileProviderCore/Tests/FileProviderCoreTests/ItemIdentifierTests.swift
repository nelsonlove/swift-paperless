//
//  ItemIdentifierTests.swift
//  FileProviderCore
//

import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct ItemIdentifierTests {
  static let cases: [(ItemIdentifier, String)] = [
    (.root, "root"),
    (.document(12), "doc:12"),
    (.document(0), "doc:0"),
    (.folder(.correspondent(12)), "dir:correspondent:12"),
    (.folder(.correspondent(nil)), "dir:correspondent:none"),
    (.folder(.documentType(3)), "dir:documentType:3"),
    (.folder(.documentType(nil)), "dir:documentType:none"),
    (.folder(.year(2026)), "dir:year:2026"),
    (.folder(.correspondentYear(correspondent: 12, year: nil)), "dir:correspondentYear:12"),
    (.folder(.correspondentYear(correspondent: 12, year: 2026)), "dir:correspondentYear:12/2026"),
    (
      .folder(.correspondentYear(correspondent: nil, year: 2026)),
      "dir:correspondentYear:none/2026"
    ),
    (.browseRoot(.tag), "browse:tag"),
    (.browseRoot(.correspondent), "browse:correspondent"),
    (.browseRoot(.documentType), "browse:type"),
    (.browseFolder(.tag, id: 4), "tag:4"),
    (.browseFolder(.correspondent, id: 1), "corr:1"),
    (.browseFolder(.documentType, id: 2), "type:2"),
    (.appearance(.tag, folderID: 4, documentID: 13), "tag:4/doc:13"),
    (.appearance(.correspondent, folderID: 1, documentID: 10), "corr:1/doc:10"),
    (.appearance(.documentType, folderID: 2, documentID: 12), "type:2/doc:12"),
    (.document(UInt.max), "doc:\(UInt.max)"),
    (.folder(.year(-1)), "dir:year:-1"),
    (.folder(.year(0)), "dir:year:0"),
    (.folder(.year(Int.min)), "dir:year:\(Int.min)"),
    (.folder(.correspondentYear(correspondent: nil, year: -44)), "dir:correspondentYear:none/-44"),
  ]

  @Test("Every identifier encodes to its documented string and decodes back")
  func roundTrip() {
    for (identifier, raw) in Self.cases {
      #expect(identifier.stringValue == raw)
      #expect(ItemIdentifier(stringValue: raw) == identifier)
    }
  }

  @Test(
    "Malformed or non-canonical strings are rejected",
    arguments: [
      "", "Root", "doc:", "doc:abc", "doc:-1", "doc:+1", "doc:012", "doc:1 ", "doc:1/doc:2",
      "dir:flat:1", "dir:storagePath:1", "dir:correspondent:", "dir:correspondent:None",
      "dir:year:none", "dir:year:02026", "dir:correspondentYear:1/", "dir:correspondentYear:1/x",
      "dir:correspondentYear:1/2026/3", "dir:correspondent", "browse:", "browse:types",
      "tag:", "tag:x", "tag:1/", "tag:1/doc:", "tag:1/dir:2", "tag:1/doc:2/doc:3", "folder:1",
      "doc:\(UInt.max)0", "doc:١٢", "dir:year:-0", "dir:year:-", "dir:year:--1",
      "dir:year:-01", "dir:year:+1", "doc:-0",
    ])
  func rejects(_ raw: String) {
    #expect(ItemIdentifier(stringValue: raw) == nil)
  }

  @Test("Codable uses the string form, also as dictionary keys")
  func codable() throws {
    let map: [ItemIdentifier: Int] = [.document(1): 1, .browseRoot(.tag): 2]
    let data = try JSONEncoder().encode(map)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
    #expect(object == ["doc:1": 1, "browse:tag": 2])
    #expect(try JSONDecoder().decode([ItemIdentifier: Int].self, from: data) == map)
  }

  @Test("Equality and hashing work on the cases, not on a string form")
  func hashingWithoutStrings() {
    // Not RawRepresentable, so the standard library's string-based == and
    // hash(into:) defaults cannot apply.
    #expect(!((ItemIdentifier.root as Any) is any RawRepresentable))

    let identifiers = Self.cases.map(\.0)
    #expect(Set(identifiers).count == identifiers.count)
    for (index, identifier) in identifiers.enumerated() {
      let copy = ItemIdentifier(stringValue: identifier.stringValue)
      #expect(copy == identifier)
      #expect(copy?.hashValue == identifier.hashValue)
      for other in identifiers[(index + 1)...] {
        #expect(identifier != other)
      }
    }
  }

  @Test("Document ids are exposed for documents and appearances only")
  func documentID() {
    #expect(ItemIdentifier.document(5).documentID == 5)
    #expect(ItemIdentifier.appearance(.tag, folderID: 1, documentID: 5).documentID == 5)
    #expect(ItemIdentifier.browseFolder(.tag, id: 5).documentID == nil)
    #expect(ItemIdentifier.root.isContainer)
    #expect(!ItemIdentifier.document(5).isContainer)
  }
}
