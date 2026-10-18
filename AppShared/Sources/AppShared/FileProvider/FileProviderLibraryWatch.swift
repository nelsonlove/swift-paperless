//
//  FileProviderLibraryWatch.swift
//  AppShared
//
//  Signals the File Provider after every write to the cached library.
//

#if canImport(FileProvider)

  import Foundation
  import Persistence

  /// Watches this process's writes to the document and element tables and
  /// signals the File Provider for every configured server, because a table
  /// region does not say which server's rows changed.
  ///
  /// One low-level watch covers every writer (syncs, fills, list paging,
  /// reconciles, edits, deletes, restores, detail refreshes) without a hook at
  /// each call site. The ``FileProviderSignaler`` coalesces the bursts.
  @MainActor
  public final class FileProviderLibraryWatch {
    private let changes: @Sendable () -> AsyncStream<Void>
    private let servers: @MainActor () -> [UUID]
    private let signal: @MainActor (UUID) -> Void
    private var task: Task<Void, Never>?

    public init(
      changes: @escaping @Sendable () -> AsyncStream<Void>,
      servers: @escaping @MainActor () -> [UUID],
      signal: @escaping @MainActor (UUID) -> Void
    ) {
      self.changes = changes
      self.servers = servers
      self.signal = signal
    }

    public convenience init(
      database: Database, connectionManager: ConnectionManager,
      signaler: FileProviderSignaler = .shared
    ) {
      self.init(
        changes: { database.observeLibraryChanges() },
        servers: { [weak connectionManager] in
          connectionManager.map { Array($0.connections.keys) } ?? []
        },
        signal: { [weak signaler] in signaler?.signal(serverID: $0) })
    }

    deinit {
      task?.cancel()
    }

    public func start() {
      guard task == nil else { return }
      let stream = changes()
      task = Task { @MainActor [weak self] in
        for await _ in stream {
          self?.signalAll()
        }
      }
    }

    public func stop() {
      task?.cancel()
      task = nil
    }

    private func signalAll() {
      for id in servers() {
        signal(id)
      }
    }
  }

#endif
