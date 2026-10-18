//
//  ContentVersionTests.swift
//  FileProviderCore
//

import DataModel
import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct ContentVersionTests {
  private func item(_ document: Document, in tree: LibraryTree) -> TreeItem {
    tree.item(for: .document(document.id))!
  }

  @Test("A title or tag change changes the metadata version only")
  func metadataOnlyEdit() {
    let document = Fixtures.documents[0]
    let before = item(document, in: Fixtures.tree(documents: [document]))

    var retitled = document
    retitled.title = "Electricity bill April 2026"
    retitled.modified = Fixtures.date(2026, 3, 1)
    var retagged = document
    retagged.tags = [1]
    retagged.modified = Fixtures.date(2026, 3, 2)

    for edited in [retitled, retagged] {
      let after = item(edited, in: Fixtures.tree(documents: [edited]))
      #expect(after.contentVersion == before.contentVersion)
      #expect(after.metadataVersion != before.metadataVersion)
    }
  }

  @Test("A new current version or checksum changes the content version")
  func contentEdit() {
    var document = Fixtures.documents[0]
    document.versions = [DocumentVersion(id: 10, added: Fixtures.date(2026), checksum: "aa", isRoot: true)]
    let base = LibraryTree.contentVersion(for: document, content: .archive)
    var newVersion = document
    newVersion.versions.append(
      DocumentVersion(id: 99, added: Fixtures.date(2026, 3), checksum: "bb", isRoot: false))
    var newChecksum = document
    newChecksum.versions[0].checksum = "cc"
    #expect(LibraryTree.contentVersion(for: newVersion, content: .archive) != base)
    #expect(LibraryTree.contentVersion(for: newChecksum, content: .archive) != base)
    #expect(base.hasSuffix("/aa"))
  }

  @Test("A metadata-only edit is still sent as an update")
  func metadataEditIsSent() {
    let document = Fixtures.documents[0]
    var edited = document
    edited.modified = Fixtures.date(2026, 4, 1)
    let diff = TreeDiff(
      from: Fixtures.tree(documents: [document]).snapshot(),
      to: Fixtures.tree(documents: [edited]).snapshot())
    #expect(diff.updated.contains(.document(document.id)))
  }
}
