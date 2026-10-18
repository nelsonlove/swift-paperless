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

  /// Replays changes the way the File Provider system applies them: an
  /// update sets the item's entry; a deletion removes the item and every item
  /// whose parent chain, at that moment, runs through it.
  private func replay(_ changes: [TreeDiff.Change], on old: TreeSnapshot, new: TreeSnapshot)
    -> TreeSnapshot
  {
    var state = old
    for change in changes {
      switch change {
      case .update(let id):
        state.entries[id] = new.entries[id]
      case .delete(let id):
        let doomed = state.entries.keys.filter { candidate in
          var current = candidate
          var steps = 0
          while steps < 64 {
            if current == id { return true }
            guard let parent = state.entries[current]?.parent else { return false }
            current = parent
            steps += 1
          }
          return false
        }
        for item in doomed { state.entries[item] = nil }
      }
    }
    return state
  }

  @Test("Updates before deletions keep a document moved out of a folder that empties")
  func moveOutOfEmptiedFolder() {
    // City Library (correspondent 3) holds only document 12; it moves to Acme.
    var changed = Fixtures.documents
    changed[2].correspondent = 1
    let flat = FileProviderSettings(layout: .correspondent, browseFolders: [])
    let old = Fixtures.tree(flat).snapshot()
    let new = Fixtures.tree(flat, documents: changed).snapshot()
    let diff = TreeDiff(from: old, to: new)
    #expect(diff.changes.contains(.update(.document(12))))
    #expect(diff.changes.contains(.delete(.folder(.correspondent(3)))))

    // The folder held a survivor, so its deletion comes after the move.
    let move = diff.changes.firstIndex(of: .update(.document(12)))!
    let removal = diff.changes.firstIndex(of: .delete(.folder(.correspondent(3))))!
    #expect(move < removal)

    // Applies changes one at a time and reports whether document 12 was ever
    // missing on the way, which for the system means it was deleted (its
    // file, Recents entry and bookmarks gone) rather than moved.
    func walk(_ changes: [TreeDiff.Change]) -> (final: TreeSnapshot, everLost: Bool) {
      var state = old
      var everLost = false
      for change in changes {
        state = replay([change], on: state, new: new)
        if state.entries[.document(12)] == nil { everLost = true }
      }
      return (state, everLost)
    }

    // The documented order (the API's only order): the document is moved and
    // never lost, and the result is the new tree.
    let documented = walk(diff.changes)
    #expect(!documented.everLost)
    #expect(documented.final.entries[.document(12)]?.parent == .folder(.correspondent(1)))
    #expect(documented.final == new)

    // The wrong order, deletions first, cannot come out of the API. Built by
    // hand, it deletes the document together with its old folder; the update
    // after that can only bring it back as a new item.
    let deletionsFirst =
      diff.changes.filter { if case .delete = $0 { true } else { false } }
      + diff.changes.filter { if case .update = $0 { true } else { false } }
    let wrong = walk(deletionsFirst)
    #expect(wrong.everLost)
  }

  /// Identifiers of items that share a name (case-insensitively after NFC)
  /// with a sibling in the given state.
  private func siblingClashes(_ state: TreeSnapshot) -> Set<ItemIdentifier> {
    var groups: [String: [ItemIdentifier]] = [:]
    for (id, entry) in state.entries {
      groups["\(entry.parent.stringValue)/\(FileNaming.comparisonKey(entry.name))", default: []]
        .append(id)
    }
    return Set(groups.values.filter { $0.count > 1 }.flatMap { $0 })
  }

  @Test("A sibling renamed to a deleted folder's name never shares it during the replay")
  func renameToDeletedName() {
    // Acme Utilities' documents are deleted, and Northwind Bank is renamed to
    // "Acme Utilities" in the same diff.
    let remaining = Fixtures.documents.filter { $0.correspondent != 1 }
    var correspondents = Fixtures.correspondents
    correspondents[1].name = "Acme Utilities"
    let old = Fixtures.tree().snapshot()
    let new = LibraryTree(
      documents: remaining, tags: Fixtures.tags, correspondents: correspondents,
      documentTypes: Fixtures.documentTypes
    ).snapshot()
    let diff = TreeDiff(from: old, to: new)
    #expect(diff.changes.contains(.delete(.folder(.correspondent(1)))))
    #expect(diff.changes.contains(.update(.folder(.correspondent(2)))))
    #expect(new.entries[.folder(.correspondent(2))]?.name == "Acme Utilities")

    // The documented order: no step ever has two siblings with one name, and
    // it ends in the new tree.
    var state = old
    #expect(siblingClashes(state).isEmpty)
    for change in diff.changes {
      state = replay([change], on: state, new: new)
      #expect(siblingClashes(state).isEmpty, "clash after \(change)")
    }
    #expect(state == new)

    // All updates before all deletions would have a step with a clash.
    let updatesFirst =
      diff.changes.filter { if case .update = $0 { true } else { false } }
      + diff.changes.filter { if case .delete = $0 { true } else { false } }
    var naive = old
    var clashed = false
    for change in updatesFirst {
      naive = replay([change], on: naive, new: new)
      if !siblingClashes(naive).isEmpty { clashed = true }
    }
    #expect(clashed)
  }

  @Test("The diff has three runs: safe deletions, updates, other deletions")
  func runs() {
    // Acme's documents are deleted (a safe deletion of its folders), and
    // City Library's only document moves to Northwind (an unsafe deletion).
    var changed = Fixtures.documents.filter { $0.correspondent != 1 }
    changed[changed.firstIndex { $0.id == 12 }!].correspondent = 2
    let diff = TreeDiff(
      from: Fixtures.tree().snapshot(), to: Fixtures.tree(documents: changed).snapshot())
    #expect(diff.runs.count == 3)
    #expect(diff.changes == diff.runs.flatMap { $0 })

    let isDelete: (TreeDiff.Change) -> Bool = {
      if case .delete = $0 { true } else { false }
    }
    #expect(diff.runs[0].allSatisfy(isDelete))
    #expect(diff.runs[1].allSatisfy { !isDelete($0) })
    #expect(diff.runs[2].allSatisfy(isDelete))
    #expect(diff.runs[0].contains(.delete(.folder(.correspondent(1)))))
    #expect(diff.runs[0].contains(.delete(.document(10))))
    #expect(diff.runs[1].contains(.update(.document(12))))
    #expect(diff.runs[2].contains(.delete(.folder(.correspondent(3)))))

    // No change: three empty runs.
    let none = TreeDiff(from: Fixtures.tree().snapshot(), to: Fixtures.tree().snapshot())
    #expect(none.runs == [[], [], []])
    #expect(none.isEmpty)
  }

  @Test("Documented limit: an unsafe deletion can briefly share a name with a new sibling")
  func unsafeDeletionNameOverlap() {
    // Layout switch from correspondent to year with a correspondent named
    // "2026": the year folder "2026" arrives while the correspondent folder
    // "2026" still holds documents moving out.
    var correspondents = Fixtures.correspondents
    correspondents[0].name = "2026"
    let settingsBefore = FileProviderSettings(layout: .correspondent, browseFolders: [])
    let settingsAfter = FileProviderSettings(layout: .year, browseFolders: [])
    func tree(_ settings: FileProviderSettings) -> LibraryTree {
      LibraryTree(
        documents: Fixtures.documents, tags: [], correspondents: correspondents,
        documentTypes: [], settings: settings)
    }
    let old = tree(settingsBefore).snapshot()
    let new = tree(settingsAfter).snapshot()
    let diff = TreeDiff(from: old, to: new)
    #expect(diff.runs[2].contains(.delete(.folder(.correspondent(1)))))

    var state = old
    var overlapped = false
    for change in diff.changes {
      state = replay([change], on: state, new: new)
      if !siblingClashes(state).isEmpty { overlapped = true }
    }
    #expect(overlapped)
    #expect(state == new)
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
