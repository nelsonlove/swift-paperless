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
/// The order is the contract: every update comes before every deletion.
/// Deleting a folder also deletes whatever the system still has inside it, so
/// an item moved out of a folder that is deleted in the same change set must
/// be re-parented first. Updates run by depth in the new snapshot, folders
/// before documents at the same depth, so every folder exists before its
/// children arrive; deletions run deepest first, so children go before their
/// folders. Report `changes` in sequence (`didUpdate` for each run of updates,
/// `didDeleteItems` for each run of deletions); there is no other public view
/// of the diff, so the updates cannot be reported after the deletions by
/// mistake.
public struct TreeDiff: Equatable, Sendable {
  public enum Change: Hashable, Sendable {
    /// A new item, or one whose parent, name or version changed.
    case update(ItemIdentifier)
    /// An item that is gone.
    case delete(ItemIdentifier)
  }

  /// All updates, then all deletions, each in the order described above.
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

    var deleted: [(id: ItemIdentifier, key: String, depth: Int)] = []
    for identifier in old.entries.keys where new.entries[identifier] == nil {
      deleted.append((identifier, identifier.stringValue, old.depth(of: identifier)))
    }
    deleted.sort { lhs, rhs in
      if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
      return lhs.key < rhs.key
    }

    changes = updated.map { .update($0.id) } + deleted.map { .delete($0.id) }
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
