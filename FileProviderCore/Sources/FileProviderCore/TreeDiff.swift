//
//  TreeDiff.swift
//  FileProviderCore
//

import Foundation

/// The change set between two ``TreeSnapshot``s, in the shape
/// `enumerateChanges` reports it.
///
/// An item with the same identifier and a new parent (a re-parented document
/// after a correspondent edit or a layout switch) is an update, never a delete
/// plus an add, so bookmarks to it survive.
public struct TreeDiff: Equatable, Sendable {
  /// New items and items whose parent, name or version changed. Ordered by
  /// depth in the new snapshot, folders before documents at the same depth,
  /// so every folder comes before its children.
  public var updated: [ItemIdentifier]
  /// Items in the old snapshot that are gone. Ordered deepest first, so
  /// children come before their folders.
  public var deleted: [ItemIdentifier]

  public var isEmpty: Bool { updated.isEmpty && deleted.isEmpty }

  public init(updated: [ItemIdentifier], deleted: [ItemIdentifier]) {
    self.updated = updated
    self.deleted = deleted
  }

  public init(from old: TreeSnapshot, to new: TreeSnapshot) {
    var updated: [(id: ItemIdentifier, depth: Int, isFolder: Bool)] = []
    for (identifier, entry) in new.entries where old.entries[identifier] != entry {
      updated.append((identifier, new.depth(of: identifier), entry.isFolder))
    }
    updated.sort { lhs, rhs in
      if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
      if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
      return lhs.id.rawValue < rhs.id.rawValue
    }

    var deleted: [(id: ItemIdentifier, depth: Int)] = []
    for identifier in old.entries.keys where new.entries[identifier] == nil {
      deleted.append((identifier, old.depth(of: identifier)))
    }
    deleted.sort { lhs, rhs in
      if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
      return lhs.id.rawValue < rhs.id.rawValue
    }

    self.updated = updated.map(\.id)
    self.deleted = deleted.map(\.id)
  }
}
