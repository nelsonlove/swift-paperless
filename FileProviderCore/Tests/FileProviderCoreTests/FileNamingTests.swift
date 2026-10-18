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

  @Test("Format characters such as a right-to-left override are dropped")
  func formatCharacters() {
    #expect(FileNaming.sanitize("Invoice\u{202E}fdp.exe") == "Invoicefdp.exe")
    #expect(FileNaming.sanitize("\u{FEFF}Bill\u{200B} 2026") == "Bill 2026")
    #expect(FileNaming.sanitize("\u{202E}\u{200B}") == nil)
    // The zero-width joiner in an emoji sequence is kept.
    #expect(FileNaming.sanitize("Family 👨\u{200D}👩\u{200D}👧") == "Family 👨\u{200D}👩\u{200D}👧")
  }

  @Test("Emoji tag characters of a subdivision flag are kept")
  func subdivisionFlag() {
    // 🏴 + TAG g b s c t + CANCEL TAG: the flag of Scotland.
    let scotland = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
    #expect(FileNaming.sanitize("Trip \(scotland) 2026") == "Trip \(scotland) 2026")
  }

  @Test("All bidi controls, U+200B and U+FEFF are dropped")
  func bidiControls() {
    let controls: [Unicode.Scalar] = [
      "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
      "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{200B}", "\u{FEFF}", "\u{00AD}",
    ]
    for control in controls {
      #expect(FileNaming.sanitize("Bill\(Character(control))s") == "Bills")
    }
  }

  @Test("The result is NFC even when a dropped character split a sequence")
  func nfcAfterDrops() throws {
    let name = try #require(FileNaming.sanitize("e\u{200B}\u{0301}"))
    #expect(name == "\u{E9}")
    #expect(name.unicodeScalars.map(\.value) == [0xE9])
  }

  @Test("A leading dot with a combining mark is stripped too")
  func leadingDotWithMark() {
    #expect(FileNaming.sanitize(".\u{0301}secret") == "\u{0301}secret")
    #expect(FileNaming.sanitize(". .\u{0301}. notes")?.unicodeScalars.first != ".")
    #expect(FileNaming.sanitize(".\u{0301}") == "\u{0301}")
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

  @Test("The untitled label is sanitized like any other name")
  func untitledLabelSanitized() {
    let document = Fixtures.document(7, "")
    #expect(FileNaming.stem(for: document, untitled: ".Doc/ument\u{202E}") == "Doc-ument 7")
    #expect(FileNaming.stem(for: document, untitled: "...") == "7")
    let tree = LibraryTree(
      documents: [document], tags: [], correspondents: [], documentTypes: [],
      settings: FileProviderSettings(layout: .flat, browseFolders: []),
      labels: TreeLabels(untitledDocument: "Scan: page"))
    #expect(tree.item(for: .document(7))?.name == "Scan- page 7.pdf")
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

  @Test("A document with no archive is served as its original, even for archive")
  func noArchive() {
    let photo = Fixtures.document(
      5, "Photo", originalFileName: "IMG_0001.heic", archivedFileName: nil)
    #expect(FileNaming.servedContent(for: photo, requested: .archive) == .original)
    #expect(FileNaming.fileName(for: photo, content: .archive) == "Photo.heic")
    #expect(FileNaming.fileName(for: photo, content: .original) == "Photo.heic")
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

  @Test("A crafted chain of suffix lookalikes still ends with unique names")
  func craftedChain() {
    // "A", "A", "A (#1)", "A (#1) (#1)", … all with disambiguator "1", so the
    // usual suffix only reproduces the next title.
    var entries = [
      FileNaming.Entry(
        stem: "A", fileExtension: "pdf", disambiguator: "1",
        uniqueKey: "doc:100")
    ]
    for level in 0..<12 {
      let stem = "A" + String(repeating: " (#1)", count: level)
      entries.append(
        FileNaming.Entry(
          stem: stem, fileExtension: "pdf", disambiguator: "1",
          uniqueKey: "doc:\(level)"))
    }
    let names = FileNaming.resolveCollisions(entries)
    #expect(names.count == 13)
    // The fallback suffix never carries the identifier's ":" or "/".
    #expect(names.allSatisfy { !$0.contains(":") && !$0.contains("/") })
    #expect(Set(names.map(FileNaming.comparisonKey)).count == names.count)
    #expect(names.allSatisfy { $0.utf8.count <= FileNaming.maxNameBytes })
    #expect(FileNaming.resolveCollisions(entries.reversed()) == names.reversed())
  }

  @Test("Final names stay within 255 bytes with a suffix and a long extension")
  func lengthCap() throws {
    let stem = try #require(FileNaming.sanitize(String(repeating: "ü", count: 300)))
    let entries = (1...3).map {
      FileNaming.Entry(
        stem: stem, fileExtension: "abcdefghijklmnop",
        disambiguator: String(UInt.max - UInt($0)), uniqueKey: "doc:\($0)")
    }
    let names = FileNaming.resolveCollisions(entries)
    #expect(Set(names).count == 3)
    for name in names {
      #expect(name.utf8.count <= FileNaming.maxNameBytes)
      #expect(name.hasSuffix(").abcdefghijklmnop"))
    }
  }

  @Test("Identifiers and disambiguators with / and : never reach a name")
  func noSeparatorsInSuffixes() {
    let entries = [
      FileNaming.Entry(stem: "A", fileExtension: nil, disambiguator: "12/2026",
        uniqueKey: "dir:correspondentYear:12/2026"),
      FileNaming.Entry(stem: "A", fileExtension: nil, disambiguator: "12/2026",
        uniqueKey: "dir:correspondentYear:none/2026"),
      FileNaming.Entry(stem: "A (#12-2026)", fileExtension: nil, disambiguator: "x:y",
        uniqueKey: "tag:1/doc:2"),
    ]
    let names = FileNaming.resolveCollisions(entries)
    #expect(Set(names.map(FileNaming.comparisonKey)).count == 3)
    #expect(names.allSatisfy { !$0.contains(":") && !$0.contains("/") })
  }

  @Test("A huge extension or key cannot stall the last resort")
  func hugeTail() {
    let ext = String(repeating: "x", count: 240)
    let key = String(repeating: "k", count: 500)
    let entries = (0..<20).map {
      FileNaming.Entry(stem: "Same", fileExtension: ext, disambiguator: "1",
        uniqueKey: "\(key)\($0)")
    }
    let names = FileNaming.resolveCollisions(entries)
    #expect(Set(names.map(FileNaming.comparisonKey)).count == 20)
    #expect(names.allSatisfy { $0.utf8.count <= FileNaming.maxNameBytes })
    #expect(names.allSatisfy { $0.hasSuffix("." + String(repeating: "x", count: 16)) })
  }

  @Test("The stable hash is fixed across runs")
  func stableHash() {
    #expect(FileNaming.stableHash("doc:1") == FileNaming.stableHash("doc:1"))
    #expect(FileNaming.stableHash("doc:1") != FileNaming.stableHash("doc:2"))
    // Reference values from an independent FNV-1a 64 implementation, folded
    // to 32 bits by xor of the halves.
    #expect(FileNaming.stableHash("") == "4fd0bfc1")
    #expect(FileNaming.stableHash("a") == "296230c0")
    #expect(FileNaming.stableHash("doc:1") == "30540a0f")
  }

  @Test("An entry that keeps its name wins; the others take the suffix")
  func keepsName() {
    let entries = [
      FileNaming.Entry(stem: "By tag", fileExtension: nil, disambiguator: "7"),
      FileNaming.Entry(stem: "By tag", fileExtension: nil, disambiguator: "tag", keepsName: true),
    ]
    #expect(FileNaming.resolveCollisions(entries) == ["By tag (#7)", "By tag"])
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
