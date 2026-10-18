//
//  TreeSnapshot.swift
//  FileProviderCore
//

import Foundation

/// What the File Provider system was last told about a tree: per item its
/// parent, name, version and metadata stamp. The extension persists one per domain and diffs
/// the next tree against it with ``TreeDiff``.
public struct TreeSnapshot: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Hashable, Sendable {
    public var parent: ItemIdentifier
    public var name: String
    public var version: String
    public var isFolder: Bool
    /// What else the item's metadata version carries beyond its parent and
    /// name (the extension puts the item's capabilities here), so a change to
    /// it is an update. Optional so a state saved before the field existed
    /// still decodes: its entries have none, differ from every current entry
    /// that has one, and are each sent once as an update.
    public var metadata: String?

    public init(
      parent: ItemIdentifier, name: String, version: String, isFolder: Bool,
      metadata: String? = nil
    ) {
      self.parent = parent
      self.name = name
      self.version = version
      self.isFolder = isFolder
      self.metadata = metadata
    }
  }

  /// Which items a snapshot holds.
  public enum Scope: Sendable {
    /// Every item except the root.
    case all
    /// The working set: every folder and every canonical document.
    case workingSet
  }

  /// Keyed by identifier; encoded as a JSON object keyed by the identifier
  /// string.
  public var entries: [ItemIdentifier: Entry]

  public init(entries: [ItemIdentifier: Entry] = [:]) {
    self.entries = entries
  }

  /// - Parameter metadata: the stamp of each item's other metadata (see
  ///   ``Entry/metadata``); `nil` records none.
  public init(_ items: [TreeItem], metadata: (TreeItem) -> String? = { _ in nil }) {
    var entries: [ItemIdentifier: Entry] = [:]
    for item in items where item.identifier != .root {
      entries[item.identifier] = Entry(
        parent: item.parent, name: item.name, version: item.version, isFolder: item.isFolder,
        metadata: metadata(item))
    }
    self.entries = entries
  }

  /// Depth below the root: 1 for a child of the root. An item whose parent
  /// chain leaves the snapshot counts the steps it has.
  func depth(of identifier: ItemIdentifier) -> Int {
    var depth = 0
    var current = identifier
    var seen = Set<ItemIdentifier>()
    while let entry = entries[current], seen.insert(current).inserted {
      depth += 1
      current = entry.parent
    }
    return depth
  }
}

extension TreeSnapshot {
  /// This snapshot after the system has applied `run`: an update takes the
  /// entry from `new`, a deletion removes the entry. Used to record what the
  /// system knows after each page of changes, so the next page starts from
  /// there and never resends a run.
  public func applying(run: [TreeDiff.Change], from new: TreeSnapshot) -> TreeSnapshot {
    var result = self
    for change in run {
      switch change {
      case .update(let identifier):
        result.entries[identifier] = new.entries[identifier]
      case .delete(let identifier):
        result.entries[identifier] = nil
      }
    }
    return result
  }
}

extension LibraryTree {
  /// A snapshot of this tree, with each item's metadata stamp from
  /// `metadata` (see ``TreeSnapshot/Entry/metadata``).
  public func snapshot(
    _ scope: TreeSnapshot.Scope = .all, metadata: (TreeItem) -> String? = { _ in nil }
  ) -> TreeSnapshot {
    switch scope {
    case .all: TreeSnapshot(allItems, metadata: metadata)
    case .workingSet: TreeSnapshot(workingSet, metadata: metadata)
    }
  }
}
