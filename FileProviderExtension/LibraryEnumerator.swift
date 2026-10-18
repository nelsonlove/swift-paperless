//
//  LibraryEnumerator.swift
//  FileProviderExtension
//

import FileProvider
import FileProviderCore
import Foundation

/// Carries a value the SDK hands over as non-Sendable (an observer, a
/// completion handler) into the main-actor task that answers it. The SDK calls
/// these from any thread and each is used once, from that one task.
struct Handoff<Value>: @unchecked Sendable {
  let value: Value
}

/// Enumerates a container of the library tree, or the working set.
///
/// Items: the container's children, folders first, or for the working set
/// every folder and every canonical document, paged with ``ItemPager``. The
/// library is reread on the first page of each enumeration.
///
/// Changes: only the working set reports them. Its `enumerateChanges` answers
/// one ``TreeDiff`` run per call with ``ChangePager`` and finishes the page with
/// `moreComing` while runs remain, saving the change state after each run, so
/// a run is never sent twice and each run is applied before the next one (see
/// ``TreeDiff``). The change state covers every item of the tree, appearances
/// included: the header says a directory the user enumerated and its children
/// belong to the working set (NSFileProviderReplicatedExtension.h,
/// enumeratorForContainerItemIdentifier). A container enumerator reports no
/// changes of its own and finishes at the anchor it was given, since every
/// change reaches the system through the working set; whether the system
/// accepts that for containers is not checked on a device.
final class LibraryEnumerator: NSObject, NSFileProviderEnumerator {
  enum Scope {
    case container(ItemIdentifier)
    case workingSet
  }

  /// Answered when the stack is the in-memory fallback and no state exists;
  /// unknown to ``ChangePager``, so it expires once a real database is back.
  static let fallbackAnchor = NSFileProviderSyncAnchor(Data("fallback".utf8))

  private let holder: ContextHolder
  private let scope: Scope
  private var tasks: [Task<Void, Never>] = []
  private let lock = NSLock()

  init(holder: ContextHolder, scope: Scope) {
    self.holder = holder
    self.scope = scope
  }

  func invalidate() {
    lock.withLock {
      for task in tasks { task.cancel() }
      tasks.removeAll()
    }
  }

  private func run(_ body: @escaping @MainActor @Sendable (ExtensionContext) async -> Void) {
    let holder = holder
    let task = Task { @MainActor in await body(holder.context) }
    lock.withLock { tasks.append(task) }
  }

  // MARK: Items

  func enumerateItems(
    for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
  ) {
    let observer = Handoff(value: observer)
    let token = page.rawValue
    let pageSize = observer.value.suggestedPageSize ?? 200
    let scope = scope
    run { context in
      do {
        guard let tree = try await context.tree(refresh: ItemPager.isFirstPage(token)) else {
          // In-memory fallback: list nothing, delete nothing.
          observer.value.finishEnumerating(upTo: nil)
          return
        }
        let items: [TreeItem]
        switch scope {
        case .workingSet:
          items = tree.workingSet
        case .container(let identifier):
          guard let children = tree.children(of: identifier) else {
            // NSFileProviderEnumerating.h / the replicated header's
            // enumeratorForContainerItemIdentifier "Error cases": an unknown
            // container fails with NSFileProviderErrorNoSuchItem.
            observer.value.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
          }
          items = children
        }
        let slice = ItemPager.page(items, token: token, size: pageSize)
        let fileProviderItems = slice.items.compactMap {
          context.item(for: $0.identifier, in: tree)
        }
        observer.value.didEnumerate(fileProviderItems)
        observer.value.finishEnumerating(upTo: slice.next.map { NSFileProviderPage($0) })
      } catch {
        observer.value.finishEnumeratingWithError(FileProviderErrors.map(error))
      }
    }
  }

  // MARK: Changes

  func enumerateChanges(
    for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
  ) {
    let observer = Handoff(value: observer)
    guard case .workingSet = scope else {
      observer.value.finishEnumeratingChanges(upTo: anchor, moreComing: false)
      return
    }
    run { context in
      do {
        guard let tree = try await context.tree(refresh: true) else {
          // In-memory fallback: report nothing, above all no deletions.
          observer.value.finishEnumeratingChanges(upTo: anchor, moreComing: false)
          return
        }
        guard let state = context.loadState() else {
          // No state to diff against (first run, or the state was lost).
          observer.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
          return
        }
        let page = try ChangePager.nextPage(
          state: state, from: anchor.rawValue, current: tree.snapshot())
        var updated: [NSFileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []
        for change in page.run {
          switch change {
          case .update(let identifier):
            if let item = context.item(for: identifier, in: tree) { updated.append(item) }
          case .delete(let identifier):
            deleted.append(identifier.fileProviderIdentifier)
          }
        }
        // Saved before the page is finished: if the save fails, the page is
        // not reported, and the next call starts from the same state.
        try context.saveState(page.state)
        if !updated.isEmpty { observer.value.didUpdate(updated) }
        if !deleted.isEmpty { observer.value.didDeleteItems(withIdentifiers: deleted) }
        observer.value.finishEnumeratingChanges(
          upTo: NSFileProviderSyncAnchor(page.anchor), moreComing: page.moreComing)
      } catch ChangePager.Failure.anchorExpired {
        // NSFileProviderError.h: "The value of the sync anchor is too old, and
        // the system must re-sync from scratch". Also the answer to the stub's
        // "stub-v1" anchor.
        observer.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
      } catch {
        observer.value.finishEnumeratingWithError(FileProviderErrors.map(error))
      }
    }
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    let handler = Handoff(value: completionHandler)
    run { context in
      if let state = context.loadState() {
        handler.value(NSFileProviderSyncAnchor(state.anchor))
        return
      }
      // No state yet: start one from the library as it is now, which is what
      // the enumeration that follows will list.
      do {
        guard let tree = try await context.tree(refresh: true) else {
          handler.value(Self.fallbackAnchor)
          return
        }
        let state = ChangePager.initialState(current: tree.snapshot())
        try context.saveState(state)
        handler.value(NSFileProviderSyncAnchor(state.anchor))
      } catch {
        ExtensionContext.logger.error("File Provider: no sync anchor: \(error)")
        handler.value(nil)
      }
    }
  }
}
