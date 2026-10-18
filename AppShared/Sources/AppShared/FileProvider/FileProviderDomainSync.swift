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
  /// The decision, domain names included (servers that share a display name,
  /// names kept stable), is ``DomainReconcile``'s; this type only applies it.
  ///
  /// Each pass starts from the in-memory server list it observes, as the
  /// reconcile's input (identifier, display name, user name). A pass whose
  /// input equals what the last pass applied in full does nothing more: no
  /// database read, no call to the system.
  /// Otherwise the pass reads the server rows from the database, so a failed
  /// hydrate cannot pass for "no servers", and works from that read.
  ///
  /// Removal is guarded three ways, because removing a domain deletes what
  /// the system holds for it:
  /// - a pass whose database read fails changes nothing;
  /// - a database that is not on disk (the in-memory fallback) never removes;
  /// - only a server that an earlier read in this process saw, and that this
  ///   read no longer holds, loses its domain. A database that was just wiped
  ///   or recreated empty therefore removes nothing.
  ///
  /// A failed add, rename or removal is logged (an add once per name) and
  /// leaves the pass unapplied, so the next change of the server list tries
  /// again; nothing retries it in a loop.
  ///
  /// Only the app runs this. The extensions never add or remove domains.
  @MainActor
  public final class FileProviderDomainSync {
    private let observed: @MainActor () -> [UUID: StoredConnection]
    private let read: @MainActor () async throws -> [UUID: StoredConnection]
    private let allowsRemoval: Bool
    private let manager: (any FileProviderDomainManaging)?
    private var observationTask: Task<Void, Never>?

    /// The servers the last pass applied in full (every add, rename and
    /// removal succeeded); `nil` before that.
    private var applied: Set<DomainReconcile.Server>?
    /// Every server identifier a successful read in this process has held.
    private var seen: Set<String> = []
    /// Adds that failed, as "identifier name", so each is logged once.
    private(set) var loggedFailures: Set<String> = []

    /// Number of database reads so far, for tests.
    private(set) var readCount = 0

    /// - Parameters:
    ///   - observed: The in-memory server list, read inside observation
    ///     tracking; a change to what it reads starts a pass.
    ///   - read: The server rows read from the database. A throw skips the
    ///     pass.
    ///   - allowsRemoval: Whether `read` reads the database on disk.
    ///   - manager: The system's domains; `nil` where there is no File
    ///     Provider extension, which makes the sync do nothing.
    public init(
      observed: @escaping @MainActor () -> [UUID: StoredConnection],
      read: @escaping @MainActor () async throws -> [UUID: StoredConnection],
      allowsRemoval: Bool,
      manager: (any FileProviderDomainManaging)? = FileProviderDomainSync.systemManager
    ) {
      self.observed = observed
      self.read = read
      self.allowsRemoval = allowsRemoval
      self.manager = manager
    }

    /// Observes `connectionManager`'s server list and reads the rows from
    /// `database`; removes domains only when `database` is on disk.
    public convenience init(
      connectionManager: ConnectionManager, database: Database,
      manager: (any FileProviderDomainManaging)? = FileProviderDomainSync.systemManager
    ) {
      self.init(
        observed: { [weak connectionManager] in connectionManager?.connections ?? [:] },
        read: {
          let records = try database.allConnections()
          return Dictionary(
            records.map { ($0.id, StoredConnection(record: $0)) },
            uniquingKeysWith: { first, _ in first })
        },
        allowsRemoval: database.isOnDisk,
        manager: manager)
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
    /// `ServerSessionRegistry.start()`; a pass finishes before the next one
    /// starts, and a change during one triggers the next.
    public func start() {
      guard manager != nil, observationTask == nil else { return }
      observationTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          let (stream, continuation) = AsyncStream<Void>.makeStream()
          let current = withObservationTracking {
            self?.observed()
          } onChange: {
            continuation.yield()
            continuation.finish()
          }
          if let current {
            await self?.pass(observed: current)
          }
          for await _ in stream { break }
        }
      }
    }

    public func stop() {
      observationTask?.cancel()
      observationTask = nil
    }

    /// One pass against the current in-memory server list.
    public func reconcile() async {
      await pass(observed: observed())
    }

    /// The reconcile's input. Domain names, including telling apart servers
    /// that share a display name and keeping names stable, are
    /// ``DomainReconcile``'s.
    private static func servers(
      _ servers: [UUID: StoredConnection]
    ) -> Set<DomainReconcile.Server> {
      Set(
        servers.map {
          DomainReconcile.Server(
            identifier: $0.key.uuidString, displayName: displayName(for: $0.value),
            userName: $0.value.user.username)
        })
    }

    private func pass(observed current: [UUID: StoredConnection]) async {
      guard let manager else { return }
      if let applied, applied == Self.servers(current) { return }

      readCount += 1
      let rows: [UUID: StoredConnection]
      do {
        rows = try await read()
      } catch {
        Logger.fileProvider.error(
          "Reading the servers failed; File Provider domains left as they are: \(error)")
        return
      }
      let wanted = Self.servers(rows)
      let existingList: [DomainReconcile.Domain]
      do {
        existingList = try await manager.domains()
      } catch {
        Logger.fileProvider.error("Reading File Provider domains failed: \(error)")
        return
      }
      let existing = Dictionary(
        existingList.map { ($0.identifier, $0.displayName) }, uniquingKeysWith: { first, _ in first })
      let result = DomainReconcile.reconcile(
        servers: wanted.sorted { $0.identifier < $1.identifier }, domains: existing)
      var complete = true

      for domain in result.add + result.renameInPlace {
        do {
          try await manager.add(domain)
          loggedFailures.remove("\(domain.identifier) \(domain.displayName)")
          Logger.fileProvider.info(
            "File Provider domain \(domain.identifier, privacy: .public) added or renamed")
        } catch {
          complete = false
          if loggedFailures.insert("\(domain.identifier) \(domain.displayName)").inserted {
            Logger.fileProvider.error(
              "Adding File Provider domain \(domain.identifier, privacy: .public) failed: \(error)")
          }
        }
      }

      let removable = result.remove.filter { allowsRemoval && seen.contains($0.identifier) }
      if removable.count < result.remove.count {
        Logger.fileProvider.notice(
          "Keeping \(result.remove.count - removable.count, privacy: .public) File Provider domain(s) whose server this process never saw in the database on disk"
        )
      }
      for domain in removable {
        do {
          try await manager.remove(domain)
          Logger.fileProvider.info(
            "File Provider domain \(domain.identifier, privacy: .public) removed")
        } catch {
          complete = false
          Logger.fileProvider.error(
            "Removing File Provider domain \(domain.identifier, privacy: .public) failed: \(error)")
        }
      }

      if allowsRemoval {
        seen.formUnion(wanted.map(\.identifier))
      }
      // Compared with the next observed list. A failure leaves the pass
      // unapplied, so the next change of the list tries again. A domain kept
      // for safety does not count as a failure.
      applied = complete ? wanted : nil
    }

    /// The server's display name handed to ``DomainReconcile``: its friendly
    /// name, else its host, else its whole URL. The domain name Files shows is
    /// derived from it there.
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
