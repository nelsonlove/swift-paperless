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

  public init(
    epoch: String, counter: UInt64, snapshot: TreeSnapshot, previousCounter: UInt64? = nil,
    previousSnapshot: TreeSnapshot? = nil
  ) {
    self.epoch = epoch
    self.counter = counter
    self.snapshot = snapshot
    self.previousCounter = previousCounter
    self.previousSnapshot = previousSnapshot
  }

  /// The anchor that names this state.
  public var anchor: Data { ChangePager.anchor(epoch: epoch, counter: counter) }
}

/// Answers `enumerateChanges` one run of a ``TreeDiff`` per call.
///
/// Each call reports the first non-empty run between the stored snapshot and
/// the current tree, advances the anchor, and stores the snapshot as it stands
/// after that run, so the next call starts after it and never resends it. The
/// caller ends each page with `finishEnumeratingChanges(upTo:moreComing:)`,
/// `moreComing` being true while more runs remain; the page break is what
/// orders the runs (see ``TreeDiff``).
public enum ChangePager {
  public enum Failure: Error, Equatable {
    /// The anchor is unknown, from another state, or from the stub
    /// ("stub-v1"); the system must re-enumerate from scratch.
    case anchorExpired
  }

  public struct Page: Equatable, Sendable {
    /// The run to report: all updates or all deletions. Empty when the system
    /// is up to date.
    public var run: [TreeDiff.Change]
    /// The anchor to finish the page with.
    public var anchor: Data
    /// Whether another run remains after this one.
    public var moreComing: Bool
    /// The state to persist before finishing the page.
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

  /// The next page of changes from `anchor`.
  ///
  /// - Throws: ``Failure/anchorExpired`` unless `anchor` is the state's
  ///   current or previous anchor.
  public static func nextPage(
    state: ChangeState, from anchor: Data, current: TreeSnapshot
  ) throws -> Page {
    let base: TreeSnapshot
    let baseCounter: UInt64
    if anchor == state.anchor {
      base = state.snapshot
      baseCounter = state.counter
    } else if let previousCounter = state.previousCounter,
      let previousSnapshot = state.previousSnapshot,
      anchor == Self.anchor(epoch: state.epoch, counter: previousCounter)
    {
      base = previousSnapshot
      baseCounter = previousCounter
    } else {
      throw Failure.anchorExpired
    }

    let diff = TreeDiff(from: base, to: current)
    guard let run = diff.runs.first(where: { !$0.isEmpty }) else {
      // Up to date: the same anchor, nothing more (the header expects the
      // anchor to change only when something was reported).
      return Page(run: [], anchor: anchor, moreComing: false, state: state)
    }

    let after = base.applying(run: run, from: current)
    let next = ChangeState(
      epoch: state.epoch, counter: max(state.counter, baseCounter) + 1, snapshot: after,
      previousCounter: baseCounter, previousSnapshot: base)
    let moreComing = !TreeDiff(from: after, to: current).isEmpty
    return Page(run: run, anchor: next.anchor, moreComing: moreComing, state: next)
  }
}

/// Pages a list of items for `enumerateItems`, with a page token that is the
/// next offset. The system's initial page tokens (sorted by name or by date)
/// and any token this type did not make start at the beginning.
public enum ItemPager {
  static let prefix = "offset:"

  /// The items of one page and the token of the next, `nil` after the last.
  public static func page<Element>(_ items: [Element], token: Data, size: Int)
    -> (items: ArraySlice<Element>, next: Data?)
  {
    let size = max(1, size)
    let start = min(offset(of: token), items.count)
    let end = min(start + size, items.count)
    let next = end < items.count ? Data("\(prefix)\(end)".utf8) : nil
    return (items[start..<end], next)
  }

  /// Whether `token` starts a new enumeration (any token this type did not
  /// make, or offset 0), the moment to reread the library.
  public static func isFirstPage(_ token: Data) -> Bool {
    offset(of: token) == 0
  }

  static func offset(of token: Data) -> Int {
    guard let text = String(data: token, encoding: .utf8), text.hasPrefix(prefix),
      let value = Int(text.dropFirst(prefix.count)), value >= 0
    else { return 0 }
    return value
  }
}
