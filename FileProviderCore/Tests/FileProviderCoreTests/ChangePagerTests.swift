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

@Suite
struct SortedItemPagerTests {
  @Test("Paging a presorted list gives the pages the sorting pager gives")
  func sameAsSortingPager() {
    let items = ["k", "b", "x", "a", "m", "c", "z", "d"]
    let sorted = ItemPager.sortedByKey(items, key: { $0 })
    #expect(sorted == items.sorted())
    for size in 1...9 {
      var token = Data()
      var tokenSorted = Data()
      while true {
        let expected = ItemPager.page(items, key: { $0 }, token: token, size: size)
        let actual = ItemPager.page(
          sortedByKey: sorted, key: { $0 }, token: tokenSorted, size: size)
        #expect(actual.items == expected.items)
        #expect(actual.next == expected.next)
        guard let next = expected.next, let nextSorted = actual.next else { break }
        token = next
        tokenSorted = nextSorted
      }
    }
    // A token naming a key that is gone starts after where it would be.
    let after = ItemPager.page(
      sortedByKey: sorted, key: { $0 }, token: Data("after:e".utf8), size: 2)
    #expect(after.items == ["k", "m"])
  }
}

@Suite
struct SnapshotMetadataTests {
  private func stamp(_ item: TreeItem) -> String? { item.isFolder ? "folder-caps" : "doc-caps" }

  @Test("A change to an item's metadata stamp alone is an update")
  func metadataChangeIsUpdate() {
    let tree = Fixtures.tree()
    let old = tree.snapshot(metadata: stamp)
    let new = tree.snapshot(metadata: { $0.isFolder ? "folder-caps-2" : "doc-caps" })
    let diff = TreeDiff(from: old, to: new)
    let folders = Set(tree.allItems.filter(\.isFolder).map(\.identifier))
    #expect(!folders.isEmpty)
    #expect(Set(diff.updated) == folders)
    #expect(diff.deleted.isEmpty)
  }

  @Test("A state saved before the stamp existed decodes, then updates every item once")
  func oldStateDecodesAndUpdates() throws {
    let tree = Fixtures.tree()
    let oldFormat = ChangePager.initialState(current: tree.snapshot(), epoch: "e")
    let data = try JSONEncoder().encode(oldFormat)
    #expect(!String(decoding: data, as: UTF8.self).contains("metadata"))
    let decoded = try JSONDecoder().decode(ChangeState.self, from: data)
    #expect(decoded.snapshot.entries.values.allSatisfy { $0.metadata == nil })

    let current = tree.snapshot(metadata: stamp)
    let page = try ChangePager.nextPage(state: decoded, from: decoded.anchor, current: current)
    #expect(Set(page.run) == Set(current.entries.keys.map { TreeDiff.Change.update($0) }))
    #expect(!page.moreComing)
    let after = try ChangePager.nextPage(state: page.state, from: page.anchor, current: current)
    #expect(after.run.isEmpty)
  }

  @Test("The stamp survives a JSON round trip")
  func stampRoundTrip() throws {
    let snapshot = Fixtures.tree().snapshot(metadata: stamp)
    let data = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(TreeSnapshot.self, from: data) == snapshot)
  }
}

@Suite
struct ChangePagerBatchTests {
  /// Every page from the state's anchor until the system is up to date, as one
  /// burst: each page passes the previous page's remaining runs as its plan.
  private func drain(
    _ state: ChangeState, to current: TreeSnapshot, batchSize: Int, burst: Bool = true
  ) throws -> [ChangePager.Page] {
    var pages: [ChangePager.Page] = []
    var state = state
    var anchor = state.anchor
    var plan: [[TreeDiff.Change]]?
    while true {
      let page = try ChangePager.nextPage(
        state: state, from: anchor, current: current, batchSize: batchSize, plan: plan)
      if page.run.isEmpty { break }
      pages.append(page)
      #expect(page.run.count <= batchSize)
      state = page.state
      anchor = page.anchor
      plan = burst ? page.remaining : nil
      #expect(pages.count < 1000)
    }
    return pages
  }

  /// The fixture library after Acme's documents are deleted, Northwind is
  /// renamed "Acme Utilities" and City Library's only document moves to
  /// Northwind.
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

  /// Whether two items under one parent share a name.
  private func hasDuplicateNames(_ snapshot: TreeSnapshot) -> Bool {
    var seen = Set<String>()
    for entry in snapshot.entries.values
    where !seen.insert("\(entry.parent.stringValue)/\(entry.name)").inserted {
      return true
    }
    return false
  }

  @Test("A run larger than the batch is sent in order across calls, exactly once")
  func largeRunInBatches() throws {
    let new = Fixtures.tree().snapshot()
    let state = ChangePager.initialState(current: TreeSnapshot(), epoch: "e")
    let updates = TreeDiff(from: TreeSnapshot(), to: new).runs[1]
    #expect(updates.count > 3)

    let pages = try drain(state, to: new, batchSize: 3)
    #expect(pages.flatMap(\.run) == updates)
    let allButLastMore = pages.dropLast().allSatisfy { $0.moreComing }
    #expect(allButLastMore)
    #expect(pages.last?.moreComing == false)
    #expect(pages.last?.state.snapshot == new)
  }

  @Test(
    "Within a burst, batched pages send every run in diff order, each change once",
    arguments: [1, 2, 5])
  func everyRunInBatches(_ batchSize: Int) throws {
    let (old, new) = scenario()
    let diff = TreeDiff(from: old, to: new)
    let pages = try drain(
      ChangePager.initialState(current: old, epoch: "e"), to: new, batchSize: batchSize)
    #expect(pages.flatMap(\.run) == diff.changes)
    #expect(pages.last?.state.snapshot == new)
  }

  @Test("Across bursts (no plan), every change is sent exactly once", arguments: [1, 2, 5])
  func everyChangeOnceAcrossBursts(_ batchSize: Int) throws {
    let (old, new) = scenario()
    let diff = TreeDiff(from: old, to: new)
    let pages = try drain(
      ChangePager.initialState(current: old, epoch: "e"), to: new, batchSize: batchSize,
      burst: false)
    let sent = pages.flatMap(\.run)
    #expect(sent.count == diff.changes.count)
    #expect(Set(sent) == Set(diff.changes))
    #expect(pages.last?.state.snapshot == new)
  }

  @Test("A page with a plan does not diff: it slices the plan")
  func planIsSliced() throws {
    let (old, new) = scenario()
    let state = ChangePager.initialState(current: old, epoch: "e")
    let only: [[TreeDiff.Change]] = [[], [.update(.document(11))], []]
    let page = try ChangePager.nextPage(
      state: state, from: state.anchor, current: new, batchSize: 5, plan: only)
    #expect(page.run == [.update(.document(11))])
    #expect(!page.moreComing)
  }

  @Test("Asked again from the previous anchor, the previous state is kept as it is")
  func previousKept() throws {
    let (old, new) = scenario()
    let state = ChangePager.initialState(current: old, epoch: "e")
    let first = try ChangePager.nextPage(
      state: state, from: state.anchor, current: new, batchSize: 2)
    let again = try ChangePager.nextPage(
      state: first.state, from: state.anchor, current: new, batchSize: 2)
    #expect(again.state.previousSnapshot == first.state.previousSnapshot)
    #expect(again.state.previousCounter == first.state.previousCounter)
    #expect(again.run == first.run)
  }

  @Test(
    "A new safe deletion from a newer read goes before the rest of a cut updates run, so no two siblings share a name"
  )
  func newSafeDeletionBeforeResumedUpdates() throws {
    // Burst 1: a new library adds every item (one updates run), cut by the batch.
    let start = LibraryTree(
      documents: Fixtures.documents, tags: Fixtures.tags,
      correspondents: Fixtures.correspondents, documentTypes: Fixtures.documentTypes
    ).snapshot()
    let state = ChangePager.initialState(current: TreeSnapshot(), epoch: "e")
    // Cut the run just after the "Acme Utilities" folder, so the system has it.
    let updates = TreeDiff(from: TreeSnapshot(), to: start).runs[1]
    let acme = try #require(
      updates.firstIndex {
        guard case .update(let id) = $0, let entry = start.entries[id] else { return false }
        return entry.isFolder && entry.name == "Acme Utilities"
      })
    let first = try ChangePager.nextPage(
      state: state, from: state.anchor, current: start, batchSize: acme + 1)
    #expect(first.moreComing)
    #expect(first.state.snapshot.entries.values.contains { $0.name == "Acme Utilities" })

    // A newer read: correspondent Acme and its documents are gone (a safe
    // deletion), and Northwind is renamed "Acme Utilities", Acme's name.
    var correspondents = Fixtures.correspondents.filter { $0.id != 1 }
    correspondents[0].name = "Acme Utilities"
    let newer = LibraryTree(
      documents: Fixtures.documents.filter { $0.correspondent != 1 }, tags: Fixtures.tags,
      correspondents: correspondents, documentTypes: Fixtures.documentTypes
    ).snapshot()

    // Every page from here, with the newer library (no plan from burst 1).
    var current = first.state
    var anchor = first.anchor
    var plan: [[TreeDiff.Change]]?
    var sawDeletionFirst: Bool?
    while true {
      let page = try ChangePager.nextPage(
        state: current, from: anchor, current: newer, batchSize: 4, plan: plan)
      if page.run.isEmpty { break }
      if sawDeletionFirst == nil, case .delete = page.run[0] { sawDeletionFirst = true }
      if sawDeletionFirst == nil { sawDeletionFirst = false }
      #expect(!hasDuplicateNames(page.state.snapshot))
      current = page.state
      anchor = page.anchor
      plan = page.remaining
    }
    #expect(sawDeletionFirst == true)
    #expect(current.snapshot == newer)
  }
}
