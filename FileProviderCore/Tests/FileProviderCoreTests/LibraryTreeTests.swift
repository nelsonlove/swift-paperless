//
//  LibraryTreeTests.swift
//  FileProviderCore
//

import DataModel
import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct LibraryTreeTests {
  private func settings(
    _ layout: FolderLayout, browse: Set<BrowseFolder> = [],
    content: FileProviderSettings.Content = .archive
  ) -> FileProviderSettings {
    FileProviderSettings(layout: layout, browseFolders: browse, content: content)
  }

  /// Every item's parent chain reaches the root, and every item is listed
  /// among its parent's children exactly once.
  private func expectConsistent(_ tree: LibraryTree) {
    for item in tree.allItems {
      var current = item.identifier
      var steps = 0
      while current != .root, steps < 100 {
        current = tree.parent(of: current) ?? .root
        steps += 1
      }
      #expect(steps < 100, "\(item.identifier) does not reach the root")
      let siblings = tree.children(of: item.parent)?.map(\.identifier) ?? []
      #expect(siblings.filter { $0 == item.identifier }.count == 1)
    }
  }

  /// Every document is in the canonical tree exactly once.
  private func expectCanonicalOnce(_ tree: LibraryTree, _ documents: [Document]) {
    let canonical = tree.allItems.compactMap { item -> UInt? in
      if case .document(let id) = item.identifier { return id }
      return nil
    }
    #expect(canonical.sorted() == documents.map(\.id).sorted())
  }

  @Test("Defaults: correspondent layout and all three browse folders")
  func defaults() {
    let tree = Fixtures.tree()
    let root = tree.children(of: .root) ?? []
    #expect(root.allSatisfy { $0.isFolder })
    #expect(
      Set(root.map(\.name)) == [
        "Acme Utilities", "Northwind Bank", "City Library", "No correspondent", "By tag",
        "By correspondent", "By type",
      ])
    expectConsistent(tree)
    expectCanonicalOnce(tree, Fixtures.documents)
  }

  @Test("Correspondent layout, with a No correspondent folder")
  func correspondentLayout() {
    let tree = Fixtures.tree(settings(.correspondent))
    #expect(
      tree.names(.root) == [
        "Acme Utilities", "City Library", "No correspondent", "Northwind Bank",
      ])
    #expect(
      tree.names(.folder(.correspondent(1))) == [
        "Electricity bill March 2026.pdf", "Water bill.pdf",
      ])
    #expect(tree.names(.folder(.correspondent(nil))) == ["Unsorted scan.pdf"])
    #expect(tree.parent(of: .document(13)) == .folder(.correspondent(nil)))
    expectConsistent(tree)
    expectCanonicalOnce(tree, Fixtures.documents)
  }

  @Test("Document type layout, with a No document type folder")
  func documentTypeLayout() {
    let tree = Fixtures.tree(settings(.documentType))
    #expect(
      tree.names(.root) == ["Invoice", "Letter", "No document type", "Statement"])
    #expect(tree.parent(of: .document(13)) == .folder(.documentType(nil)))
    #expect(tree.names(.folder(.documentType(1))).count == 2)
    expectConsistent(tree)
    expectCanonicalOnce(tree, Fixtures.documents)
  }

  @Test("Year layout groups by the created year")
  func yearLayout() {
    let tree = Fixtures.tree(settings(.year))
    #expect(tree.names(.root) == ["2025", "2026"])
    #expect(tree.names(.folder(.year(2025))) == ["Account statement Q1.pdf", "Water bill.pdf"])
    expectConsistent(tree)
    expectCanonicalOnce(tree, Fixtures.documents)
  }

  /// Midnight on a day in a given UTC offset, as `DateOnlyCodable` would
  /// decode it in that zone.
  private func localMidnight(_ year: Int, _ month: Int, _ day: Int, offsetHours: Double) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: Int(offsetHours * 3600))!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
  }

  @Test("The created year does not depend on the zone it was decoded in")
  func createdYearAcrossZones() {
    // Decoded at UTC+1 on 1 January: 2025-12-31T23:00Z. A tree built in UTC-5
    // with that zone's calendar would say 2025.
    let decodedAtPlusOne = localMidnight(2026, 1, 1, offsetHours: 1)
    var minusFive = Calendar(identifier: .gregorian)
    minusFive.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
    #expect(minusFive.component(.year, from: decodedAtPlusOne) == 2025)
    #expect(LibraryTree.createdYear(decodedAtPlusOne) == 2026)

    // Hawaii (-10), the Marquesas (-9:30), New York (-5), UTC, Paris (+1),
    // Tokyo (+9), Auckland standard (+12), Chatham (+12:45), and Auckland
    // summer, Samoa and Tonga (+13).
    for offset in [-10, -9.5, -5, 0, 1, 9, 12, 12.75, 13] {
      #expect(LibraryTree.createdYear(localMidnight(2026, 1, 1, offsetHours: offset)) == 2026)
      #expect(LibraryTree.createdYear(localMidnight(2025, 12, 31, offsetHours: offset)) == 2025)
    }

    // Kiritimati (+14) is the one populated zone outside the window. It
    // cannot be inside it together with Hawaii: their midnights coincide one
    // calendar day apart, so a rule on the instant must pick one of them.
    let hawaiiNewYear = localMidnight(2026, 1, 1, offsetHours: -10)
    let kiritimatiNextDay = localMidnight(2026, 1, 2, offsetHours: 14)
    #expect(hawaiiNewYear == kiritimatiNextDay)
    #expect(LibraryTree.createdYear(localMidnight(2026, 12, 31, offsetHours: -10)) == 2026)

    var document = Fixtures.document(1, "New year letter")
    document.created = decodedAtPlusOne
    let tree = Fixtures.tree(settings(.year), documents: [document])
    #expect(tree.parent(of: .document(1)) == .folder(.year(2026)))
  }

  @Test("Correspondent and year layout nests years in correspondents")
  func correspondentYearLayout() {
    let tree = Fixtures.tree(settings(.correspondentYear))
    let acme = ItemIdentifier.folder(.correspondentYear(correspondent: 1, year: nil))
    #expect(tree.names(acme) == ["2025", "2026"])
    #expect(
      tree.parent(of: .document(14))
        == .folder(.correspondentYear(correspondent: 1, year: 2025)))
    #expect(
      tree.parent(of: .document(13))
        == .folder(.correspondentYear(correspondent: nil, year: 2026)))
    #expect(
      tree.parent(of: .folder(.correspondentYear(correspondent: nil, year: 2026)))
        == .folder(.correspondentYear(correspondent: nil, year: nil)))
    expectConsistent(tree)
    expectCanonicalOnce(tree, Fixtures.documents)
  }

  @Test("Flat layout puts every document in the root")
  func flatLayout() {
    let tree = Fixtures.tree(settings(.flat))
    let root = tree.children(of: .root) ?? []
    #expect(root.count == Fixtures.documents.count)
    #expect(root.allSatisfy { !$0.isFolder })
    expectCanonicalOnce(tree, Fixtures.documents)
  }

  @Test("Folders come first, then documents, each by name")
  func ordering() {
    let tree = Fixtures.tree(settings(.flat, browse: [.tag]))
    let root = tree.children(of: .root) ?? []
    #expect(root.first?.identifier == .browseRoot(.tag))
    let names = root.dropFirst().map(\.name)
    #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
  }

  @Test("By tag nests by Tag.parent and only shows tags with documents")
  func nestedTags() {
    let tree = Fixtures.tree(settings(.flat, browse: [.tag]))
    #expect(tree.names(.browseRoot(.tag)) == ["home", "inbox", "tax"])
    #expect(
      tree.names(.browseFolder(.tag, id: 3)) == ["insurance", "Electricity bill March 2026.pdf"])
    #expect(tree.names(.browseFolder(.tag, id: 4)) == ["Unsorted scan.pdf", "Water bill.pdf"])
    #expect(tree.parent(of: .browseFolder(.tag, id: 4)) == .browseFolder(.tag, id: 3))
    expectConsistent(tree)
  }

  @Test("A document with no tags has no appearance under By tag")
  func untaggedDocument() {
    let tree = Fixtures.tree(settings(.correspondent, browse: [.tag]))
    let appearances = tree.allItems.filter {
      if case .appearance(_, _, 12) = $0.identifier { return true }
      return false
    }
    #expect(appearances.isEmpty)
    #expect(tree.item(for: .document(12)) != nil)
  }

  @Test("Tag parent cycles, self-parents and missing parents are handled safely")
  func tagCycles() {
    let tags = [
      Fixtures.tag(5, "alpha", parent: 6),
      Fixtures.tag(6, "beta", parent: 5),
      Fixtures.tag(7, "gamma", parent: 5),
      Fixtures.tag(8, "self", parent: 8),
      Fixtures.tag(9, "orphan", parent: 99),
    ]
    let documents = [Fixtures.document(1, "Cycle doc", tags: [7, 8, 9, 6])]
    let tree = Fixtures.tree(settings(.flat, browse: [.tag]), documents: documents, tags: tags)
    #expect(tree.names(.browseRoot(.tag)) == ["alpha", "beta", "orphan", "self"])
    #expect(tree.parent(of: .browseFolder(.tag, id: 7)) == .browseFolder(.tag, id: 5))
    expectConsistent(tree)
  }

  @Test("Secondary appearances share the canonical version and stay out of the working set")
  func appearances() throws {
    let tree = Fixtures.tree()
    let canonical = try #require(tree.item(for: .document(14)))
    let identifiers: [ItemIdentifier] = [
      .appearance(.tag, folderID: 4, documentID: 14),
      .appearance(.tag, folderID: 2, documentID: 14),
      .appearance(.correspondent, folderID: 1, documentID: 14),
      .appearance(.documentType, folderID: 1, documentID: 14),
    ]
    for identifier in identifiers {
      let item = try #require(tree.item(for: identifier))
      #expect(item.version == canonical.version)
      #expect(item.name == canonical.name)
      #expect(tree.document(for: identifier)?.id == 14)
    }
    #expect(tree.parent(of: identifiers[0]) == .browseFolder(.tag, id: 4))

    let workingSet = tree.workingSet
    #expect(
      workingSet.allSatisfy {
        if case .appearance = $0.identifier { return false }
        return $0.identifier != .root
      })
    let folders = tree.allItems.filter(\.isFolder).map(\.identifier)
    #expect(
      Set(workingSet.map(\.identifier))
        == Set(folders + Fixtures.documents.map { .document($0.id) }))
  }

  @Test("The working set lists every folder before its children")
  func workingSetOrder() {
    let ids = Fixtures.tree().workingSet.map(\.identifier)
    let tree = Fixtures.tree()
    for (index, identifier) in ids.enumerated() {
      guard let parent = tree.parent(of: identifier), parent != .root else { continue }
      #expect(ids.firstIndex(of: parent).map { $0 < index } == true)
    }
  }

  @Test("Lookups for unknown items and non-containers return nil")
  func lookups() {
    let tree = Fixtures.tree()
    #expect(tree.item(for: .document(999)) == nil)
    #expect(tree.parent(of: .folder(.year(2026))) == nil)
    #expect(tree.children(of: .document(10)) == nil)
    #expect(tree.children(of: .browseFolder(.tag, id: 999)) == nil)
    #expect(tree.parent(of: .root) == .root)
  }

  @Test("Disabled browse folders are absent")
  func browseDisabled() {
    let tree = Fixtures.tree(settings(.correspondent, browse: [.documentType]))
    #expect(tree.item(for: .browseRoot(.tag)) == nil)
    #expect(tree.item(for: .browseRoot(.correspondent)) == nil)
    #expect(tree.names(.browseRoot(.documentType)) == ["Invoice", "Letter", "Statement"])
  }

  @Test("An id missing from the element lists gets a fallback folder name")
  func unknownElement() {
    let documents = [Fixtures.document(1, "Mystery", correspondent: 77, type: 88, tags: [99])]
    let tree = Fixtures.tree(.default, documents: documents)
    #expect(tree.item(for: .folder(.correspondent(77)))?.name == "Correspondent 77")
    #expect(tree.item(for: .browseFolder(.documentType, id: 88))?.name == "Document type 88")
    #expect(tree.item(for: .browseFolder(.tag, id: 99))?.name == "Tag 99")
  }

  @Test("Same-named documents and folders in one folder get id suffixes")
  func collisions() {
    let documents = [
      Fixtures.document(21, "Bill", correspondent: 1),
      Fixtures.document(20, "bill", correspondent: 1),
      Fixtures.document(22, "Receipt", correspondent: 5),
    ]
    var correspondents = Fixtures.correspondents
    correspondents.append(Fixtures.correspondent(5, "Acme Utilities"))
    let tree = LibraryTree(
      documents: documents, tags: [], correspondents: correspondents,
      documentTypes: [], settings: settings(.correspondent))
    #expect(tree.names(.folder(.correspondent(1))) == ["bill (#20).pdf", "Bill (#21).pdf"])
    #expect(tree.names(.root) == ["Acme Utilities (#1)", "Acme Utilities (#5)"])
  }

  @Test("document(for:) is nil for an identifier not in the tree")
  func documentLookupConsistent() {
    let tree = Fixtures.tree()
    #expect(tree.document(for: .document(10))?.id == 10)
    #expect(tree.document(for: .appearance(.tag, folderID: 1, documentID: 10))?.id == 10)
    // Document 10 exists, but not under tag 2 or in a folder that does not exist.
    let missing: [ItemIdentifier] = [
      .appearance(.tag, folderID: 2, documentID: 10),
      .appearance(.correspondent, folderID: 999, documentID: 10),
    ]
    for identifier in missing {
      #expect(tree.item(for: identifier) == nil)
      #expect(tree.document(for: identifier) == nil)
    }
    let flat = Fixtures.tree(settings(.flat))
    #expect(flat.document(for: .appearance(.tag, folderID: 1, documentID: 10)) == nil)
  }

  @Test("The tree does not depend on the input order of documents")
  func inputOrder() {
    let forward = Fixtures.tree().snapshot()
    let backward = Fixtures.tree(documents: Fixtures.documents.reversed()).snapshot()
    let shuffled = Fixtures.tree(documents: [
      Fixtures.documents[3], Fixtures.documents[0], Fixtures.documents[4],
      Fixtures.documents[2], Fixtures.documents[1],
    ]).snapshot()
    #expect(forward == backward)
    #expect(forward == shuffled)
  }

  @Test("Labels and element names are sanitized as folder names")
  func folderNamesSanitized() {
    let labels = TreeLabels(
      byTag: "By/tag", byCorrespondent: "\u{202E}", noCorrespondent: "No: one",
      unknownDocumentType: "Kind/")
    var correspondents = Fixtures.correspondents
    correspondents.append(Fixtures.correspondent(8, ".hidden/name"))
    let documents = [
      Fixtures.document(1, "One", correspondent: 8, type: 77),
      Fixtures.document(2, "Two"),
    ]
    let tree = LibraryTree(
      documents: documents, tags: [], correspondents: correspondents, documentTypes: [],
      settings: FileProviderSettings(layout: .correspondent), labels: labels)
    #expect(tree.item(for: .browseRoot(.tag))?.name == "By-tag")
    #expect(tree.item(for: .browseRoot(.correspondent))?.name == "correspondent")
    #expect(tree.item(for: .folder(.correspondent(nil)))?.name == "No- one")
    #expect(tree.item(for: .folder(.correspondent(8)))?.name == "hidden-name")
    #expect(tree.item(for: .browseFolder(.documentType, id: 77))?.name == "Kind- 77")
  }

  @Test("A canonical folder named like a browse root takes the suffix")
  func browseRootKeepsLabel() {
    let documents = [Fixtures.document(1, "Label sheet", correspondent: 9)]
    var correspondents = Fixtures.correspondents
    correspondents.append(Fixtures.correspondent(9, "By tag"))
    let tree = LibraryTree(
      documents: documents, tags: [], correspondents: correspondents, documentTypes: [],
      settings: settings(.correspondent, browse: [.tag]))
    #expect(tree.item(for: .browseRoot(.tag))?.name == "By tag")
    #expect(tree.item(for: .folder(.correspondent(9)))?.name == "By tag (#9)")
  }

  @Test("Original content uses the original's extension and changes the version")
  func originalContent() throws {
    let documents = [Fixtures.document(1, "Photo", originalFileName: "IMG_0001.heic")]
    let archive = Fixtures.tree(settings(.flat), documents: documents)
    let original = Fixtures.tree(settings(.flat, content: .original), documents: documents)
    let a = try #require(archive.item(for: .document(1)))
    let o = try #require(original.item(for: .document(1)))
    #expect(a.name == "Photo.pdf")
    #expect(o.name == "Photo.heic")
    #expect(a.version != o.version)
  }

  @Test("A document with no archive gets the original's name and version under archive")
  func noArchive() throws {
    let documents = [
      Fixtures.document(1, "Photo", originalFileName: "IMG_0001.heic", archivedFileName: nil)
    ]
    let archive = Fixtures.tree(settings(.flat), documents: documents)
    let original = Fixtures.tree(settings(.flat, content: .original), documents: documents)
    let a = try #require(archive.item(for: .document(1)))
    let o = try #require(original.item(for: .document(1)))
    #expect(a.name == "Photo.heic")
    #expect(a.version.hasPrefix("original:"))
    #expect(a.version == o.version)
  }

  @Test("A duplicated id keeps the latest modified copy, whatever the input order")
  func duplicateInput() {
    let older = Fixtures.document(1, "One", modified: Fixtures.date(2026, 1, 1))
    let newer = Fixtures.document(1, "One revised", modified: Fixtures.date(2026, 3, 1))
    var undated = Fixtures.document(1, "Zzz")
    undated.modified = nil
    for documents in [[older, newer, undated], [undated, newer, older], [newer, older]] {
      let tree = Fixtures.tree(settings(.flat), documents: documents)
      #expect(tree.names(.root) == ["One revised.pdf"])
      #expect(tree.document(for: .document(1))?.title == "One revised")
    }

    // Same modified date: the tiebreak is the title, in either order.
    let a = Fixtures.document(2, "Alpha")
    let b = Fixtures.document(2, "Beta")
    #expect(Fixtures.tree(settings(.flat), documents: [a, b]).names(.root) == ["Beta.pdf"])
    #expect(Fixtures.tree(settings(.flat), documents: [b, a]).names(.root) == ["Beta.pdf"])
  }
}
