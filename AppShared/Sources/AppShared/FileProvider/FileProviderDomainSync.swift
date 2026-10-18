//
//  FileProviderDomainSync.swift
//  AppShared
//
//  Keeps one File Provider domain per configured server, named after it.
//

#if canImport(FileProvider)

  import FileProviderCore
  import Foundation
  import Persistence
  import os

  #if os(iOS) && !targetEnvironment(macCatalyst)
    import FileProvider
  #endif

  /// The system's File Provider domains, as the domain sync sees them.
  public protocol FileProviderDomainManaging: Sendable {
    func domains() async throws -> [DomainReconcile.Domain]
    /// Adds the domain, or renames it in place when its identifier exists.
    func add(_ domain: DomainReconcile.Domain) async throws
    /// Removes the domain and everything the system holds for it.
    func remove(_ domain: DomainReconcile.Domain) async throws
  }

  /// Reconciles the system's File Provider domains against the `server` rows:
  /// a server with no domain gets one, a domain whose server is gone is
  /// removed, and a renamed server's domain is renamed in place by adding it
  /// again (never removed, which would drop its files, Recents and bookmarks).
  /// The decision is ``DomainReconcile``'s; this type only applies it.
  ///
  /// The server list each pass works from is a fresh read of the database, not
  /// an in-memory copy, so a failed hydrate cannot pass for "no servers". A
  /// pass whose read fails changes nothing, and a database that is not on disk
  /// (the in-memory bootstrap fallback) never removes a domain.
  ///
  /// Only the app runs this. The extensions never add or remove domains.
  @MainActor
  public final class FileProviderDomainSync {
    private let trigger: @MainActor () -> Void
    private let servers: @MainActor () async throws -> [UUID: StoredConnection]
    private let allowsRemoval: Bool
    private let manager: (any FileProviderDomainManaging)?
    private var observationTask: Task<Void, Never>?

    /// - Parameters:
    ///   - trigger: Read inside observation tracking; a change to what it
    ///     reads starts a pass.
    ///   - servers: The configured servers, read at the start of each pass.
    ///     A throw skips the pass.
    ///   - allowsRemoval: Whether `servers` reads the real database, so a
    ///     server missing from it is really gone.
    ///   - manager: The system's domains; `nil` where there is no File
    ///     Provider extension, which makes the sync do nothing.
    public init(
      trigger: @escaping @MainActor () -> Void,
      servers: @escaping @MainActor () async throws -> [UUID: StoredConnection],
      allowsRemoval: Bool,
      manager: (any FileProviderDomainManaging)? = FileProviderDomainSync.systemManager
    ) {
      self.trigger = trigger
      self.servers = servers
      self.allowsRemoval = allowsRemoval
      self.manager = manager
    }

    /// Wakes on `connectionManager`'s server list and reads the rows from
    /// `database`.
    public convenience init(connectionManager: ConnectionManager, database: Database) {
      self.init(
        trigger: { [weak connectionManager] in _ = connectionManager?.connections },
        servers: {
          let records = try database.allConnections()
          return Dictionary(
            records.map { ($0.id, StoredConnection(record: $0)) },
            uniquingKeysWith: { first, _ in first })
        },
        allowsRemoval: database.isOnDisk)
    }

    deinit {
      observationTask?.cancel()
    }

    /// The system's domains where the File Provider extension is embedded (iOS),
    /// else `nil`.
    public nonisolated static var systemManager: (any FileProviderDomainManaging)? {
      #if os(iOS) && !targetEnvironment(macCatalyst)
        SystemFileProviderDomains()
      #else
        nil
      #endif
    }

    /// Reconcile now and again whenever the servers change. Same loop as
    /// `ServerSessionRegistry.start()`; a reconcile finishes before the next
    /// one starts, and a change during one triggers the next.
    public func start() {
      guard manager != nil, observationTask == nil else { return }
      observationTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          let (stream, continuation) = AsyncStream<Void>.makeStream()
          withObservationTracking {
            self?.trigger()
          } onChange: {
            continuation.yield()
            continuation.finish()
          }
          await self?.reconcile()
          for await _ in stream { break }
        }
      }
    }

    public func stop() {
      observationTask?.cancel()
      observationTask = nil
    }

    /// One pass against a fresh read of the servers.
    public func reconcile() async {
      guard let manager else { return }
      let current: [UUID: StoredConnection]
      do {
        current = try await servers()
      } catch {
        Logger.fileProvider.error(
          "Reading the servers failed; File Provider domains left as they are: \(error)")
        return
      }
      let wanted = Dictionary(
        uniqueKeysWithValues: current.map { ($0.key.uuidString, Self.displayName(for: $0.value)) })
      let existing: [DomainReconcile.Domain]
      do {
        existing = try await manager.domains()
      } catch {
        Logger.fileProvider.error("Reading File Provider domains failed: \(error)")
        return
      }
      let result = DomainReconcile.reconcile(
        servers: wanted,
        domains: Dictionary(
          existing.map { ($0.identifier, $0.displayName) }, uniquingKeysWith: { first, _ in first }))
      guard !result.isEmpty else { return }

      for domain in result.add + result.renameInPlace {
        do {
          try await manager.add(domain)
          Logger.fileProvider.info(
            "File Provider domain \(domain.identifier, privacy: .public) added or renamed")
        } catch {
          Logger.fileProvider.error(
            "Adding File Provider domain \(domain.identifier, privacy: .public) failed: \(error)")
        }
      }
      if !result.remove.isEmpty, !allowsRemoval {
        Logger.fileProvider.notice(
          "Not removing \(result.remove.count, privacy: .public) File Provider domain(s): the server list is not from the database on disk"
        )
      }
      for domain in allowsRemoval ? result.remove : [] {
        do {
          try await manager.remove(domain)
          Logger.fileProvider.info(
            "File Provider domain \(domain.identifier, privacy: .public) removed")
        } catch {
          Logger.fileProvider.error(
            "Removing File Provider domain \(domain.identifier, privacy: .public) failed: \(error)")
        }
      }
    }

    /// The location name in Files: the server's friendly name, else its host,
    /// else its whole URL.
    public nonisolated static func displayName(for server: StoredConnection) -> String {
      if let name = server.friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines),
        !name.isEmpty
      {
        return name
      }
      if let host = server.url.host(), !host.isEmpty {
        return host
      }
      return server.url.absoluteString
    }
  }

  #if os(iOS) && !targetEnvironment(macCatalyst)
    /// `NSFileProviderManager`'s domain calls.
    struct SystemFileProviderDomains: FileProviderDomainManaging {
      func domains() async throws -> [DomainReconcile.Domain] {
        try await NSFileProviderManager.domains().map {
          DomainReconcile.Domain(identifier: $0.identifier.rawValue, displayName: $0.displayName)
        }
      }

      func add(_ domain: DomainReconcile.Domain) async throws {
        try await NSFileProviderManager.add(Self.system(domain))
      }

      func remove(_ domain: DomainReconcile.Domain) async throws {
        try await NSFileProviderManager.remove(Self.system(domain))
      }

      private static func system(_ domain: DomainReconcile.Domain) -> NSFileProviderDomain {
        NSFileProviderDomain(
          identifier: NSFileProviderDomainIdentifier(domain.identifier),
          displayName: domain.displayName)
      }
    }
  #endif

#endif
