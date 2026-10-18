//
//  ChangePager.swift
//  FileProviderCore
//

import Foundation

/// What the extension persists per domain to answer `enumerateChanges`: the
/// snapshot the system has been told about, under a sync anchor, plus the one
/// before it.
///
/// The previous anchor is kept because the working-set contract allows the
/// system to ask again from "the last requested sync anchor or the last
/// returned sync anchor" (NSFileProviderReplicatedExtension.h, "Working set
/// enumerator"), for example when a reply was lost. Any other anchor has
/// expired.
public struct ChangeState: Codable, Equatable, Sendable {
  /// Random per state, so an anchor from a state that was deleted and rebuilt
  /// never matches a new one with the same counter.
  public var epoch: String
  public var counter: UInt64
  public var snapshot: TreeSnapshot
  public var previousCounter: UInt64?
  public var previousSnapshot: TreeSnapshot?
  /// The index in ``TreeDiff/runs`` of a run that was only partly sent (it
  /// was larger than the batch), so the next page resumes it before any other
  /// run. `nil` when the last page ended a run. Optional so a state saved
  /// before the field existed still decodes.
  public var resumeRun: Int?
  /// ``resumeRun`` as it was at the previous anchor.
  public var previousResumeRun: Int?

  public init(
    epoch: String, counter: UInt64, snapshot: TreeSnapshot, previousCounter: UInt64? = nil,
    previousSnapshot: TreeSnapshot? = nil, resumeRun: Int? = nil,
    previousResumeRun: Int? = nil
  ) {
    self.epoch = epoch
    self.counter = counter
    self.snapshot = snapshot
    self.previousCounter = previousCounter
    self.previousSnapshot = previousSnapshot
    self.resumeRun = resumeRun
    self.previousResumeRun = previousResumeRun
  }

  /// The anchor that names this state.
  public var anchor: Data { ChangePager.anchor(epoch: epoch, counter: counter) }
}

/// Answers `enumerateChanges` one run of a ``TreeDiff`` per call, or one batch
/// of a run larger than the batch size.
///
/// Each call reports the first non-empty run between the stored snapshot and
/// the current tree (at most `batchSize` changes of it), advances the anchor,
/// and stores the snapshot as it stands after what it sent, so the next call
/// starts after it and never resends it. A run cut by the batch size is
/// resumed by the next call before any other run (``ChangeState/resumeRun``):
/// the diff from the stored snapshot holds exactly the rest of that run, in
/// the same order, so nothing is sent twice or skipped. The caller ends each
/// page with `finishEnumeratingChanges(upTo:moreComing:)`, `moreComing` being
/// true while changes remain; the page break is what orders the runs (see
/// ``TreeDiff``). The system suggests a batch size
/// (NSFileProviderEnumerating.h, `suggestedBatchSize`, lines 116-132 in the
/// iOS 26.5 SDK: "it is suggested it split the list of changes into several
/// batches").
public enum ChangePager {
  public enum Failure: Error, Equatable {
    /// The anchor is unknown, from another state, or from the stub
    /// ("stub-v1"); the system must re-enumerate from scratch.
    case anchorExpired
  }

  public struct Page: Equatable, Sendable {
    /// The changes to report, from one run: all updates or all deletions, at
    /// most the batch size. Empty when the system is up to date.
    public var run: [TreeDiff.Change]
    /// The anchor to finish the page with.
    public var anchor: Data
    /// Whether changes remain after this page.
    public var moreComing: Bool
    /// The state to persist before finishing the page. When ``run`` is empty
    /// it is the state passed in, and need not be saved again.
    public var state: ChangeState
  }

  static let anchorPrefix = "fp1:"

  static func anchor(epoch: String, counter: UInt64) -> Data {
    Data("\(anchorPrefix)\(epoch):\(counter)".utf8)
  }

  /// A new state at counter 1 whose snapshot is `current`, for a domain with
  /// no stored state when the system first asks for the current anchor.
  public static func initialState(
    current: TreeSnapshot, epoch: String = UUID().uuidString
  ) -> ChangeState {
    ChangeState(epoch: epoch, counter: 1, snapshot: current)
  }

  /// The next page of changes from `anchor`, at most `batchSize` changes
  /// (a size below 1 counts as 1). The diff is computed once.
  ///
  /// - Throws: ``Failure/anchorExpired`` unless `anchor` is the state's
  ///   current or previous anchor.
  public static func nextPage(
    state: ChangeState, from anchor: Data, current: TreeSnapshot, batchSize: Int = .max
  ) throws -> Page {
    let base: TreeSnapshot
    let baseCounter: UInt64
    let resumeRun: Int?
    if anchor == state.anchor {
      base = state.snapshot
      baseCounter = state.counter
      resumeRun = state.resumeRun
    } else if let previousCounter = state.previousCounter,
      let previousSnapshot = state.previousSnapshot,
      anchor == Self.anchor(epoch: state.epoch, counter: previousCounter)
    {
      base = previousSnapshot
      baseCounter = previousCounter
      resumeRun = state.previousResumeRun
    } else {
      throw Failure.anchorExpired
    }

    let diff = TreeDiff(from: base, to: current)
    // A run cut by the batch size goes on first. Without it, a part of the
    // updates run that moved every survivor out of a folder would turn that
    // folder's deletion safe, and run 1 would jump ahead of the other updates.
    let index: Int
    if let resumeRun, diff.runs.indices.contains(resumeRun), !diff.runs[resumeRun].isEmpty {
      index = resumeRun
    } else if let first = diff.runs.firstIndex(where: { !$0.isEmpty }) {
      index = first
    } else {
      // Up to date: the same anchor, nothing more (the header expects the
      // anchor to change only when something was reported).
      return Page(run: [], anchor: anchor, moreComing: false, state: state)
    }

    let full = diff.runs[index]
    let run = Array(full.prefix(max(1, batchSize)))
    let cut = run.count < full.count
    let after = base.applying(run: run, from: current)
    let next = ChangeState(
      epoch: state.epoch, counter: max(state.counter, baseCounter) + 1, snapshot: after,
      previousCounter: baseCounter, previousSnapshot: base, resumeRun: cut ? index : nil,
      previousResumeRun: resumeRun)
    // What remains is the rest of this run and every other run: the changes
    // of different runs never share an identifier.
    let moreComing =
      cut || diff.runs.indices.contains { $0 != index && !diff.runs[$0].isEmpty }
    return Page(run: run, anchor: next.anchor, moreComing: moreComing, state: next)
  }
}

/// Pages a list of items for `enumerateItems`.
///
/// Items are served in the order of a stable key (the extension uses the
/// identifier string), and a page token names the key of the last item
/// served. The next page starts after that key in whatever list the next call
/// gets, so a library reread between two pages neither repeats nor skips an
/// item that is in both lists: an item that appears meanwhile with a smaller
/// key is not listed in this enumeration, and reaches the system as a change.
/// The system's initial page tokens (sorted by name or by date) and any token
/// this type did not make start at the beginning. The order is not the one
/// Files shows; Files sorts the items itself.
public enum ItemPager {
  static let prefix = "after:"

  /// The items of one page and the token of the next, `nil` after the last.
  public static func page<Element>(
    _ items: [Element], key: (Element) -> String, token: Data, size: Int
  ) -> (items: [Element], next: Data?) {
    let size = max(1, size)
    let after = lastKey(of: token)
    var keyed = items.map { (key: key($0), item: $0) }
    if let after { keyed.removeAll { $0.key <= after } }
    keyed.sort { $0.key < $1.key }
    let pageItems = keyed.prefix(size)
    let next =
      keyed.count > size ? pageItems.last.map { Data("\(prefix)\($0.key)".utf8) } : nil
    return (pageItems.map(\.item), next)
  }

  /// ``page(_:key:token:size:)`` for items already in ascending order of
  /// `key` (the extension sorts the working set once per library read): finds
  /// the start by binary search and sorts nothing. The result is the same.
  public static func page<Element>(
    sortedByKey items: [Element], key: (Element) -> String, token: Data, size: Int
  ) -> (items: [Element], next: Data?) {
    let size = max(1, size)
    var start = 0
    if let after = lastKey(of: token) {
      // The first index whose key is greater than `after`.
      var high = items.count
      while start < high {
        let middle = (start + high) / 2
        if key(items[middle]) <= after {
          start = middle + 1
        } else {
          high = middle
        }
      }
    }
    let end = min(items.count, start + size)
    let pageItems = Array(items[start..<end])
    let next =
      end < items.count ? pageItems.last.map { Data("\(prefix)\(key($0))".utf8) } : nil
    return (pageItems, next)
  }

  /// Sorts `items` in the order ``page(sortedByKey:key:token:size:)`` expects.
  public static func sortedByKey<Element>(_ items: [Element], key: (Element) -> String)
    -> [Element]
  {
    items.map { (key: key($0), item: $0) }.sorted { $0.key < $1.key }.map(\.item)
  }

  /// Whether `token` starts a new enumeration (any token this type did not
  /// make), the moment to reread the library.
  public static func isFirstPage(_ token: Data) -> Bool {
    lastKey(of: token) == nil
  }

  static func lastKey(of token: Data) -> String? {
    guard let text = String(data: token, encoding: .utf8), text.hasPrefix(prefix) else {
      return nil
    }
    return String(text.dropFirst(prefix.count))
  }
}
