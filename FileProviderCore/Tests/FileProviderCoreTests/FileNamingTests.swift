//
//  FileNamingTests.swift
//  FileProviderCore
//

import DataModel
import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct FileNamingTests {
  @Test("Slashes, colons and control characters are replaced")
  func replacements() {
    #expect(FileNaming.sanitize("Invoice 2026/03") == "Invoice 2026-03")
    #expect(FileNaming.sanitize("Re: renewal") == "Re- renewal")
    #expect(FileNaming.sanitize("Line one\nLine two\ttab") == "Line one Line two tab")
    #expect(FileNaming.sanitize("bell\u{07}here") == "bell here")
    #expect(FileNaming.sanitize("a\u{2028}b") == "a b")
  }

  @Test("Whitespace is trimmed and collapsed; leading dots are removed")
  func trimming() {
    #expect(FileNaming.sanitize("  Water   bill  ") == "Water bill")
    #expect(FileNaming.sanitize(".hidden") == "hidden")
    #expect(FileNaming.sanitize(". . config") == "config")
  }

  @Test("Output is NFC")
  func nfc() {
    let decomposed = "Cafe\u{301} receipt"
    let name = FileNaming.sanitize(decomposed)
    #expect(name == "Caf\u{E9} receipt")
    #expect(name?.unicodeScalars.count == "Caf\u{E9} receipt".unicodeScalars.count)
  }

  @Test("Non-Latin titles and emoji are kept")
  func unicode() {
    #expect(FileNaming.sanitize("Rechnung März") == "Rechnung März")
    #expect(FileNaming.sanitize("請求書 2026") == "請求書 2026")
    #expect(FileNaming.sanitize("Bill 🧾") == "Bill 🧾")
  }

  @Test("An empty or blank title falls back to a stable name from the id")
  func emptyTitle() {
    for title in ["", "   ", "\n", "..."] {
      let document = Fixtures.document(42, title)
      #expect(FileNaming.fileName(for: document, content: .archive) == "Document 42.pdf")
    }
  }

  @Test("Long titles are capped by UTF-8 bytes on a character boundary")
  func longTitle() throws {
    let name = try #require(FileNaming.sanitize(String(repeating: "é", count: 300)))
    #expect(name.utf8.count <= FileNaming.maxStemBytes)
    #expect(name.allSatisfy { $0 == "é" })
  }

  @Test("Archive is always pdf; original uses the original's extension")
  func extensions() {
    let scan = Fixtures.document(1, "Scan", originalFileName: "scan.JPG")
    #expect(FileNaming.fileName(for: scan, content: .archive) == "Scan.pdf")
    #expect(FileNaming.fileName(for: scan, content: .original) == "Scan.JPG")

    let noOriginal = Fixtures.document(2, "Letter")
    #expect(FileNaming.fileName(for: noOriginal, content: .original) == "Letter.pdf")

    let noExtension = Fixtures.document(3, "Notes", originalFileName: "notes")
    #expect(FileNaming.fileName(for: noExtension, content: .original) == "Notes.pdf")

    let odd = Fixtures.document(4, "Odd", originalFileName: "odd.p d/f")
    #expect(FileNaming.fileName(for: odd, content: .original) == "Odd.pdf")
  }

  @Test("Colliding names all get the id suffix; others are untouched")
  func collisions() {
    let entries = [
      FileNaming.Entry(stem: "Invoice", fileExtension: "pdf", disambiguator: "7"),
      FileNaming.Entry(stem: "invoice", fileExtension: "PDF", disambiguator: "3"),
      FileNaming.Entry(stem: "Receipt", fileExtension: "pdf", disambiguator: "5"),
      FileNaming.Entry(stem: "Invoice", fileExtension: nil, disambiguator: "9"),
    ]
    #expect(
      FileNaming.resolveCollisions(entries) == [
        "Invoice (#7).pdf", "invoice (#3).PDF", "Receipt.pdf", "Invoice",
      ])
  }

  @Test("Collision names do not depend on input order")
  func collisionsDeterministic() {
    let entries = (1...6).map {
      FileNaming.Entry(
        stem: $0 % 2 == 0 ? "Bill" : "Note", fileExtension: "pdf",
        disambiguator: String($0))
    }
    let forward = Dictionary(
      uniqueKeysWithValues: zip(entries.map(\.disambiguator), FileNaming.resolveCollisions(entries))
    )
    let reversedEntries = Array(entries.reversed())
    let backward = Dictionary(
      uniqueKeysWithValues: zip(
        reversedEntries.map(\.disambiguator), FileNaming.resolveCollisions(reversedEntries)))
    #expect(forward == backward)
    #expect(forward["2"] == "Bill (#2).pdf")
    #expect(forward["1"] == "Note (#1).pdf")
  }

  @Test("A title that mimics a suffix still ends up unique")
  func suffixLookalike() {
    let entries = [
      FileNaming.Entry(stem: "Bill", fileExtension: "pdf", disambiguator: "1"),
      FileNaming.Entry(stem: "Bill", fileExtension: "pdf", disambiguator: "2"),
      FileNaming.Entry(stem: "Bill (#1)", fileExtension: "pdf", disambiguator: "3"),
    ]
    let names = FileNaming.resolveCollisions(entries)
    #expect(Set(names.map(FileNaming.comparisonKey)).count == 3)
  }

  @Test("NFC and NFD spellings of one name collide")
  func collisionsAcrossNormalization() {
    let entries = [
      FileNaming.Entry(stem: "Caf\u{E9}", fileExtension: "pdf", disambiguator: "1"),
      FileNaming.Entry(stem: "Cafe\u{301}", fileExtension: "pdf", disambiguator: "2"),
    ]
    #expect(FileNaming.resolveCollisions(entries).allSatisfy { $0.contains("(#") })
  }
}
