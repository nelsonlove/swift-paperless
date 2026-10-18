//
//  ChangePagerTests.swift
//  FileProviderCore
//

import DataModel
import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct ChangePagerTests {
  /// Old: the fixture library. New: Acme's documents deleted (safe deletions),
  /// Northwind renamed to "Acme Utilities" (an update), and City Library's
  /// only document moved to Northwind (an update, then an unsafe deletion).
  private func scenario() -> (old: TreeSnapshot, new: TreeSnapshot) {
    var documents = Fixtures.documents.filter { $0.correspondent != 1 }
    documents[documents.firstIndex { $0.id == 12 }!].correspondent = 2
    var correspondents = Fixtures.correspondents
    correspondents[1].name = "Acme Utilities"
    let new = LibraryTree(
      documents: documents, tags: Fixtures.tags, correspondents: correspondents,
      documentTypes: Fixtures.documentTypes
    ).snapshot()
    return (Fixtures.tree().snapshot(), new)
  }

  @Test("Successive calls report run 1, then run 2, then run 3, never a run twice")
  func runsInTurn() throws {
    let (old, new) = scenario()
    let diff = TreeDiff(from: old, to: new)
    #expect(diff.runs.allSatisfy { !$0.isEmpty })

    let state = ChangePager.initialState(current: old, epoch: "e")
    let first = try ChangePager.nextPage(state: state, from: state.anchor, current: new)
    #expect(first.run == diff.runs[0])
    #expect(first.moreComing)
    #expect(first.anchor != state.anchor)

    let second = try ChangePager.nextPage(state: first.state, from: first.anchor, current: new)
    #expect(second.run == diff.runs[1])
    #expect(second.moreComing)
    #expect(Set(second.run).isDisjoint(with: Set(first.run)))

    let third = try ChangePager.nextPage(state: second.state, from: second.anchor, current: new)
    #expect(third.run == diff.runs[2])
    #expect(!third.moreComing)
    #expect(third.state.snapshot == new)

    let done = try ChangePager.nextPage(state: third.state, from: third.anchor, current: new)
    #expect(done.run.isEmpty)
    #expect(!done.moreComing)
    #expect(done.anchor == third.anchor)
    #expect(done.state == third.state)
  }

  @Test("The previous anchor may be asked again; the run is then resent once")
  func previousAnchor() throws {
    let (old, new) = scenario()
    let state = ChangePager.initialState(current: old, epoch: "e")
    let first = try ChangePager.nextPage(state: state, from: state.anchor, current: new)
    // The reply was lost; the system asks from the anchor it last requested.
    let again = try ChangePager.nextPage(state: first.state, from: state.anchor, current: new)
    #expect(again.run == first.run)
    #expect(again.anchor != first.anchor)
    // Going forward from the new anchor continues with run 2.
    let second = try ChangePager.nextPage(state: again.state, from: again.anchor, current: new)
    #expect(second.run == TreeDiff(from: old, to: new).runs[1])
  }

  @Test(
    "Unknown, foreign and stub anchors have expired",
    arguments: [
      Data("stub-v1".utf8), Data(), Data("fp1:other:1".utf8), Data("fp1:e:99".utf8),
      Data("garbage".utf8),
    ])
  func expired(_ anchor: Data) {
    let state = ChangePager.initialState(current: Fixtures.tree().snapshot(), epoch: "e")
    #expect(throws: ChangePager.Failure.anchorExpired) {
      try ChangePager.nextPage(state: state, from: anchor, current: state.snapshot)
    }
  }

  @Test("An anchor older than the previous one has expired")
  func olderAnchor() throws {
    let (old, new) = scenario()
    let state = ChangePager.initialState(current: old, epoch: "e")
    let first = try ChangePager.nextPage(state: state, from: state.anchor, current: new)
    let second = try ChangePager.nextPage(state: first.state, from: first.anchor, current: new)
    #expect(throws: ChangePager.Failure.anchorExpired) {
      try ChangePager.nextPage(state: second.state, from: state.anchor, current: new)
    }
  }

  @Test("The state survives a JSON round trip")
  func codable() throws {
    let (old, new) = scenario()
    let state = ChangePager.initialState(current: old, epoch: "e")
    let page = try ChangePager.nextPage(state: state, from: state.anchor, current: new)
    let data = try JSONEncoder().encode(page.state)
    #expect(try JSONDecoder().decode(ChangeState.self, from: data) == page.state)
  }

  @Test("Applying a run takes updates from the new snapshot and drops deletions")
  func applyingRun() {
    let (old, new) = scenario()
    let diff = TreeDiff(from: old, to: new)
    var state = old
    for run in diff.runs {
      state = state.applying(run: run, from: new)
    }
    #expect(state == new)
    let afterDeletes = old.applying(run: diff.runs[0], from: new)
    #expect(afterDeletes.entries[.document(10)] == nil)
    #expect(
      afterDeletes.entries[.folder(.correspondent(2))] == old.entries[.folder(.correspondent(2))])
  }
}

@Suite
struct ItemPagerTests {
  private func walk(_ lists: [[String]], size: Int) -> [String] {
    var token = Data("anything the system sends first".utf8)
    var served: [String] = []
    var call = 0
    while true {
      // Each call may see a different list, as after a library reread.
      let list = lists[min(call, lists.count - 1)]
      let page = ItemPager.page(list, key: { $0 }, token: token, size: size)
      served += page.items
      call += 1
      guard let next = page.next else { break }
      token = next
    }
    return served
  }

  @Test("Pages walk the list in key order; foreign tokens start at the beginning")
  func paging() {
    let items = (0..<7).map { "doc:\($0)" }.shuffled()
    #expect(walk([items], size: 3) == items.sorted())
    #expect(ItemPager.page([String](), key: { $0 }, token: Data(), size: 3).next == nil)
    #expect(ItemPager.isFirstPage(Data("anything".utf8)))
    let first = ItemPager.page(items, key: { $0 }, token: Data(), size: 3)
    #expect(!ItemPager.isFirstPage(first.next!))
  }

  @Test("A reread between pages neither repeats nor drops an item that is in both lists")
  func rereadBetweenPages() {
    let before = ["a", "b", "c", "d", "e", "f", "g"]
    // Between pages: "b" (already served) and "f" are gone, "aa" and "ff"
    // appeared, one before and one after the cursor.
    let after = ["a", "aa", "c", "d", "e", "ff", "g"]
    let served = walk([before, after, after, after], size: 2)
    #expect(served.count == Set(served).count, "an item was served twice")
    for item in Set(before).intersection(after) {
      #expect(served.contains(item), "\(item) was dropped")
    }
    #expect(served.contains("ff"))
  }
}

@Suite
struct ItemVersionTests {
  @Test("The metadata version changes with the name or the parent, not the content")
  func metadataVersion() {
    let item = TreeItem(
      identifier: .document(1), parent: .folder(.correspondent(1)), name: "A.pdf",
      kind: .document, version: "archive:1/1")
    var renamed = item
    renamed.name = "B.pdf"
    var moved = item
    moved.parent = .folder(.correspondent(2))
    var edited = item
    edited.version = "archive:1/2"
    #expect(renamed.metadataVersion != item.metadataVersion)
    #expect(moved.metadataVersion != item.metadataVersion)
    #expect(edited.metadataVersion == item.metadataVersion)
    #expect(edited.contentVersion != item.contentVersion)
    let folder = TreeItem(
      identifier: .folder(.year(2026)), parent: .root, name: "2026", kind: .folder, version: "")
    #expect(folder.contentVersion == "folder")
  }
}
