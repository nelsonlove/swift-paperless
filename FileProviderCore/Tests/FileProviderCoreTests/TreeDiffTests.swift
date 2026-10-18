//
//  TreeDiffTests.swift
//  FileProviderCore
//

import DataModel
import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct TreeDiffTests {
  private func diff(
    _ old: [Document], _ new: [Document], oldSettings: FileProviderSettings = .default,
    newSettings: FileProviderSettings = .default
  ) -> TreeDiff {
    TreeDiff(
      from: Fixtures.tree(oldSettings, documents: old).snapshot(),
      to: Fixtures.tree(newSettings, documents: new).snapshot())
  }

  /// Every updated item comes after its parent when the parent is updated too.
  private func expectFoldersFirst(_ diff: TreeDiff, _ tree: LibraryTree) {
    for (index, identifier) in diff.updated.enumerated() {
      guard let parent = tree.parent(of: identifier),
        let parentIndex = diff.updated.firstIndex(of: parent)
      else { continue }
      #expect(parentIndex < index, "\(parent) should come before \(identifier)")
    }
  }

  @Test("No change gives an empty diff")
  func unchanged() {
    #expect(diff(Fixtures.documents, Fixtures.documents).isEmpty)
  }

  @Test("A new document is updated with its new folders, folders first")
  func newDocument() {
    let added = Fixtures.document(30, "Library card", correspondent: 3, type: 2, tags: [3, 4])
    let newDocuments = Fixtures.documents + [added]
    let result = diff(Fixtures.documents, newDocuments)
    #expect(result.deleted.isEmpty)
    #expect(result.updated.contains(.document(30)))
    #expect(result.updated.contains(.appearance(.tag, folderID: 4, documentID: 30)))
    expectFoldersFirst(result, Fixtures.tree(documents: newDocuments))

    // A brand-new folder comes before the document inside it.
    let fresh = Fixtures.document(31, "Ticket", correspondent: 2, type: 1, year: 2024)
    let yearSettings = FileProviderSettings(layout: .year, browseFolders: [])
    let yearDiff = diff(
      Fixtures.documents, Fixtures.documents + [fresh], oldSettings: yearSettings,
      newSettings: yearSettings)
    #expect(yearDiff.updated == [.folder(.year(2024)), .document(31)])
  }

  @Test("A changed document is updated wherever it appears")
  func changedDocument() {
    var changed = Fixtures.documents
    changed[0].modified = Fixtures.date(2026, 3, 1)
    let result = diff(Fixtures.documents, changed)
    #expect(result.deleted.isEmpty)
    #expect(
      Set(result.updated) == [
        .document(10),
        .appearance(.tag, folderID: 1, documentID: 10),
        .appearance(.tag, folderID: 3, documentID: 10),
        .appearance(.correspondent, folderID: 1, documentID: 10),
        .appearance(.documentType, folderID: 1, documentID: 10),
      ])
  }

  @Test("A renamed document is updated")
  func renamedDocument() {
    var changed = Fixtures.documents
    changed[2].title = "Membership renewal 2027"
    let result = diff(Fixtures.documents, changed)
    #expect(result.updated.contains(.document(12)))
  }

  @Test("A re-parented document keeps its identifier; an emptied folder is deleted")
  func reparented() {
    var changed = Fixtures.documents
    changed[2].correspondent = 1  // City Library held only this document
    let result = diff(Fixtures.documents, changed)
    #expect(result.updated.contains(.document(12)))
    #expect(!result.deleted.contains(.document(12)))
    #expect(result.updated.contains(.appearance(.correspondent, folderID: 1, documentID: 12)))
    #expect(result.deleted.contains(.folder(.correspondent(3))))
    #expect(result.deleted.contains(.browseFolder(.correspondent, id: 3)))
    #expect(result.deleted.contains(.appearance(.correspondent, folderID: 3, documentID: 12)))

    let new = Fixtures.tree(documents: changed).snapshot()
    #expect(new.entries[.document(12)]?.parent == .folder(.correspondent(1)))
  }

  @Test("A deleted document and its appearances are deleted, children before folders")
  func deletedDocument() {
    let remaining = Fixtures.documents.filter { $0.id != 13 }
    let result = diff(Fixtures.documents, remaining)
    #expect(result.updated.isEmpty)
    #expect(
      Set(result.deleted) == [
        .document(13),
        .appearance(.tag, folderID: 4, documentID: 13),
        .folder(.correspondent(nil)),
      ])
    let documentIndex = result.deleted.firstIndex(of: .document(13))!
    let folderIndex = result.deleted.firstIndex(of: .folder(.correspondent(nil)))!
    #expect(documentIndex < folderIndex)
  }

  @Test("A layout switch re-parents every document instead of deleting it")
  func layoutSwitch() {
    let result = diff(
      Fixtures.documents, Fixtures.documents,
      newSettings: FileProviderSettings(layout: .year))
    for document in Fixtures.documents {
      #expect(result.updated.contains(.document(document.id)))
      #expect(!result.deleted.contains(.document(document.id)))
    }
    #expect(result.deleted.contains(.folder(.correspondent(1))))
    #expect(result.updated.contains(.folder(.year(2026))))
    expectFoldersFirst(result, Fixtures.tree(FileProviderSettings(layout: .year)))
  }

  @Test("Snapshots survive a JSON round trip")
  func snapshotCodable() throws {
    let snapshot = Fixtures.tree().snapshot()
    let data = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(TreeSnapshot.self, from: data) == snapshot)
    #expect(TreeDiff(from: snapshot, to: snapshot).isEmpty)
  }

  @Test("The working-set snapshot leaves appearances and the root out")
  func workingSetSnapshot() {
    let snapshot = Fixtures.tree().snapshot(.workingSet)
    #expect(snapshot.entries[.root] == nil)
    #expect(
      snapshot.entries.keys.allSatisfy {
        if case .appearance = $0 { return false }
        return true
      })
    #expect(snapshot.entries[.document(10)] != nil)
  }
}
