//
//  LibraryEnumerator.swift
//  FileProviderExtension
//

import FileProvider
import FileProviderCore
import Foundation

/// Carries a value the SDK hands over as non-Sendable (an observer, a
/// completion handler) into the task that answers it. The SDK calls these
/// from any thread and each is used once, from that one task.
struct Handoff<Value>: @unchecked Sendable {
  let value: Value
}

/// Enumerates a container of the library tree, or the working set.
///
/// Items: the container's children, or for the working set every folder and
/// every canonical document, paged with ``ItemPager`` by identifier, so a
/// library reread between pages neither repeats nor skips an item. The
/// library is reread on the first page of each enumeration.
///
/// Changes: only the working set reports them. Its `enumerateChanges` answers
/// one ``TreeDiff`` run per call with ``ChangePager`` and finishes the page with
/// `moreComing` while runs remain, saving the change state after each run, so
/// a run is never sent twice and each run is applied before the next one (see
/// ``TreeDiff``). The pages of one burst diff against one library read, kept
/// for ``ExtensionContext/burstLifetime`` at most and dropped when the burst
/// ends, fails, is cancelled or the enumerator is invalidated. The
/// change state covers every item of the tree, appearances included: the
/// header says a directory the user enumerated and its children belong to the
/// working set (NSFileProviderReplicatedExtension.h,
/// enumeratorForContainerItemIdentifier). A container enumerator reports no
/// changes of its own and finishes at the anchor it was given, since every
/// change reaches the system through the working set; whether the system
/// accepts that for containers is not checked on a device.
///
/// A library that cannot be read fails the call with
/// NSFileProviderErrorServerUnreachable ("in case the item cannot be fetched
/// because of the current state of the system / domain", the header's
/// enumeratorForContainerItemIdentifier "Error cases", line 183 in the iOS
/// 26.5 SDK), so the system backs off and keeps what it has.
final class LibraryEnumerator: NSObject, NSFileProviderEnumerator {
  enum Scope: Sendable {
    case container(ItemIdentifier)
    case workingSet
  }

  /// Items per page when the system suggests none.
  static let defaultPageSize = 200

  private let holder: ContextHolder
  private let scope: Scope
  private let tasks = TaskBag()

  init(holder: ContextHolder, scope: Scope) {
    self.holder = holder
    self.scope = scope
  }

  func invalidate() {
    tasks.cancelAll()
    // A burst this enumerator was in the middle of is over: a later signal
    // reads the library afresh.
    if case .workingSet = scope {
      let holder = holder
      Task { @MainActor in holder.context.endBurst() }
    }
  }

  private func run(_ body: @escaping @MainActor @Sendable (ExtensionContext) async -> Void) {
    let holder = holder
    tasks.run { @MainActor in await body(holder.context) }
  }

  // MARK: Items

  func enumerateItems(
    for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
  ) {
    let observer = Handoff(value: observer)
    let token = page.rawValue
    let pageSize = observer.value.suggestedPageSize ?? Self.defaultPageSize
    let scope = scope
    run { context in
      do {
        let library = try await context.library(refresh: ItemPager.isFirstPage(token))
        let slice: (items: [TreeItem], next: Data?)
        switch scope {
        case .workingSet:
          // Sorted once per library read, off the main actor.
          slice = ItemPager.page(
            sortedByKey: library.workingSet, key: { $0.identifier.stringValue }, token: token,
            size: pageSize)
        case .container(let identifier):
          guard let children = library.tree.children(of: identifier) else {
            // The library was read and has no such container: the header's
            // enumeratorForContainerItemIdentifier "Error cases" ask for
            // NSFileProviderErrorNoSuchItem.
            observer.value.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
          }
          slice = ItemPager.page(
            children, key: { $0.identifier.stringValue }, token: token, size: pageSize)
        }
        let fileProviderItems = slice.items.compactMap {
          context.item(for: $0.identifier, in: library)
        }
        ExtensionContext.logger.notice(
          "File Provider: enumerated \(fileProviderItems.count, privacy: .public) item(s), more: \(slice.next != nil, privacy: .public)"
        )
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
    let anchorData = anchor.rawValue
    run { context in
      do {
        let library = try await context.libraryForChanges()
        guard let state = await context.loadState() else {
          // No state to diff against (first run, or the state was lost).
          context.endBurst()
          observer.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
          return
        }
        let page = try await Task.detached(priority: .userInitiated) {
          try ChangePager.nextPage(state: state, from: anchorData, current: library.snapshot)
        }.value
        // Invalidated meanwhile: report nothing and save nothing, so the next
        // call starts from the same state; the burst is over.
        try Task.checkCancellation()
        var updated: [NSFileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []
        for change in page.run {
          switch change {
          case .update(let identifier):
            if let item = context.item(for: identifier, in: library) { updated.append(item) }
          case .delete(let identifier):
            deleted.append(identifier.fileProviderIdentifier)
          }
        }
        // Saved before the page is finished: if the save fails, the page is
        // not reported, and the next call starts from the same state.
        try await context.saveState(page.state)
        // A burst invalidated while the state was saved is over; the page is
        // still reported, since the state already records it.
        if page.moreComing, !Task.isCancelled {
          context.continueBurst(with: library)
        } else {
          context.endBurst()
        }
        if !updated.isEmpty { observer.value.didUpdate(updated) }
        if !deleted.isEmpty { observer.value.didDeleteItems(withIdentifiers: deleted) }
        observer.value.finishEnumeratingChanges(
          upTo: NSFileProviderSyncAnchor(page.anchor), moreComing: page.moreComing)
      } catch ChangePager.Failure.anchorExpired {
        // NSFileProviderError.h: "The value of the sync anchor is too old, and
        // the system must re-sync from scratch". Also the answer to the stub's
        // "stub-v1" anchor.
        context.endBurst()
        observer.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
      } catch {
        // Failed or cancelled (FileProviderErrors maps a cancellation to
        // NSUserCancelledError): the burst is over either way.
        context.endBurst()
        observer.value.finishEnumeratingWithError(FileProviderErrors.map(error))
      }
    }
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    let handler = Handoff(value: completionHandler)
    run { context in
      do {
        handler.value(NSFileProviderSyncAnchor(try await context.changeState().anchor))
      } catch {
        ExtensionContext.logger.error("File Provider: no sync anchor: \(error)")
        handler.value(nil)
      }
    }
  }
}
