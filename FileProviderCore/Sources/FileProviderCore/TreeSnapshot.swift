//
//  TreeSnapshot.swift
//  FileProviderCore
//

import Foundation

/// What the File Provider system was last told about a tree: per item its
/// parent, name and version. The extension persists one per domain and diffs
/// the next tree against it with ``TreeDiff``.
public struct TreeSnapshot: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Hashable, Sendable {
    public var parent: ItemIdentifier
    public var name: String
    public var version: String
    public var isFolder: Bool

    public init(parent: ItemIdentifier, name: String, version: String, isFolder: Bool) {
      self.parent = parent
      self.name = name
      self.version = version
      self.isFolder = isFolder
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

  public init(_ items: [TreeItem]) {
    var entries: [ItemIdentifier: Entry] = [:]
    for item in items where item.identifier != .root {
      entries[item.identifier] = Entry(
        parent: item.parent, name: item.name, version: item.version, isFolder: item.isFolder)
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

extension LibraryTree {
  /// A snapshot of this tree.
  public func snapshot(_ scope: TreeSnapshot.Scope = .all) -> TreeSnapshot {
    switch scope {
    case .all: TreeSnapshot(allItems)
    case .workingSet: TreeSnapshot(workingSet)
    }
  }
}
