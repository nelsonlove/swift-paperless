//
//  TreeDiff.swift
//  FileProviderCore
//

import Foundation

/// The change set between two ``TreeSnapshot``s, as one ordered list that
/// `enumerateChanges` reports in order.
///
/// An item with the same identifier and a new parent (a re-parented document
/// after a correspondent edit or a layout switch) is an update, never a delete
/// plus an add, so bookmarks to it survive.
///
/// The order is the contract, in three runs:
///
/// 1. Safe deletions, deepest first: deletions whose subtree in the old
///    snapshot holds no item that survives in the new one. Sending them first
///    frees their names, so a sibling renamed to a deleted item's name never
///    shares it with that item.
/// 2. All updates, by depth in the new snapshot, folders before documents at
///    the same depth, so every folder exists before its children arrive.
/// 3. The other deletions, deepest first. Deleting a folder also deletes
///    whatever the system still has inside it, so a folder that held a
///    surviving item is deleted only after that item has moved out.
///
/// Report `changes` in sequence (`didUpdate` for each run of updates,
/// `didDeleteItems` for each run of deletions); there is no other public view
/// of the diff, so the runs cannot be reordered by mistake.
public struct TreeDiff: Equatable, Sendable {
  public enum Change: Hashable, Sendable {
    /// A new item, or one whose parent, name or version changed.
    case update(ItemIdentifier)
    /// An item that is gone.
    case delete(ItemIdentifier)
  }

  /// Safe deletions, then updates, then the other deletions, as described
  /// above.
  public let changes: [Change]

  public var isEmpty: Bool { changes.isEmpty }

  public init(from old: TreeSnapshot, to new: TreeSnapshot) {
    var updated: [(id: ItemIdentifier, key: String, depth: Int, isFolder: Bool)] = []
    for (identifier, entry) in new.entries where old.entries[identifier] != entry {
      updated.append(
        (identifier, identifier.stringValue, new.depth(of: identifier), entry.isFolder))
    }
    updated.sort { lhs, rhs in
      if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
      if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
      return lhs.key < rhs.key
    }

    // Every old ancestor of an item that survives holds a survivor.
    var holdsSurvivor = Set<ItemIdentifier>()
    for identifier in old.entries.keys where new.entries[identifier] != nil {
      var current = old.entries[identifier]?.parent
      while let parent = current, holdsSurvivor.insert(parent).inserted {
        current = old.entries[parent]?.parent
      }
    }

    var deleted: [(id: ItemIdentifier, key: String, depth: Int, safe: Bool)] = []
    for identifier in old.entries.keys where new.entries[identifier] == nil {
      deleted.append(
        (
          identifier, identifier.stringValue, old.depth(of: identifier),
          !holdsSurvivor.contains(identifier)
        ))
    }
    deleted.sort { lhs, rhs in
      if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
      return lhs.key < rhs.key
    }

    changes =
      deleted.filter(\.safe).map { .delete($0.id) }
      + updated.map { .update($0.id) }
      + deleted.filter { !$0.safe }.map { .delete($0.id) }
  }

  /// The updated identifiers, in order. For tests.
  var updated: [ItemIdentifier] {
    changes.compactMap {
      if case .update(let id) = $0 { return id }
      return nil
    }
  }

  /// The deleted identifiers, in order. For tests.
  var deleted: [ItemIdentifier] {
    changes.compactMap {
      if case .delete(let id) = $0 { return id }
      return nil
    }
  }
}
