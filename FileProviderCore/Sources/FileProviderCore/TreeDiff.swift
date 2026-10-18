//
//  TreeDiff.swift
//  FileProviderCore
//

import Foundation

/// The change set between two ``TreeSnapshot``s, in three ordered runs that
/// `enumerateChanges` reports one page per run.
///
/// An item with the same identifier and a new parent (a re-parented document
/// after a correspondent edit or a layout switch) is an update, never a delete
/// plus an add, so bookmarks to it survive.
///
/// The runs, in order:
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
/// How to report them: for each non-empty run in ``runs``, call `didUpdate`
/// or `didDeleteItems` with that run, then end the page with
/// `finishEnumeratingChanges(upTo:moreComing: true)` (`false` after the
/// last run), so each run is applied before the next one starts. Apple does
/// not document the order in which the system applies the changes within one
/// page, so the order inside a page must not be relied on; the page break is
/// what makes the runs ordered. (Not checked on a device.)
///
/// What the order does not prevent: an unsafe deletion (a folder that still
/// held a surviving item) is sent after the updates, so for the length of one
/// page a new or renamed sibling can share that folder's name. Two examples:
/// a layout switch from correspondent to year, when a correspondent is
/// named "2026", adds the year folder "2026" while the correspondent folder
/// "2026" still holds documents that are moving out; and a merge of
/// correspondent "Acme" into a renamed "Acme" (the old folder's documents
/// move to the other one, which takes the name) renames the other folder
/// while the old "Acme" still holds them.
public struct TreeDiff: Equatable, Sendable {
  public enum Change: Hashable, Sendable {
    /// A new item, or one whose parent, name, version or metadata stamp
    /// changed.
    case update(ItemIdentifier)
    /// An item that is gone.
    case delete(ItemIdentifier)
  }

  /// Always three runs, in order: safe deletions, updates, other deletions.
  /// A run may be empty; an empty run needs no page.
  public let runs: [[Change]]

  /// The runs flattened, in order.
  public var changes: [Change] { runs.flatMap { $0 } }

  public var isEmpty: Bool { runs.allSatisfy(\.isEmpty) }

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

    runs = [
      deleted.filter(\.safe).map { .delete($0.id) },
      updated.map { .update($0.id) },
      deleted.filter { !$0.safe }.map { .delete($0.id) },
    ]
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
