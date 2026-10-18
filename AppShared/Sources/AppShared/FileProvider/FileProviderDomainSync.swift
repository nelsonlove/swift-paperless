//
//  FileProviderDomainSync.swift
//  AppShared
//
//  Keeps one File Provider domain per configured server, named after it.
//

#if canImport(FileProvider)

  import FileProviderCore
  import Foundation
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
  /// Only the app runs this. The extensions never add or remove domains.
  @MainActor
  public final class FileProviderDomainSync {
    private let connections: @MainActor () -> [UUID: StoredConnection]
    private let manager: (any FileProviderDomainManaging)?
    private var observationTask: Task<Void, Never>?

    /// - Parameters:
    ///   - connections: The configured servers; read inside observation
    ///     tracking, so a change to what it reads triggers a reconcile.
    ///   - manager: The system's domains; `nil` where there is no File
    ///     Provider extension, which makes the sync do nothing.
    public init(
      connections: @escaping @MainActor () -> [UUID: StoredConnection],
      manager: (any FileProviderDomainManaging)? = FileProviderDomainSync.systemManager
    ) {
      self.connections = connections
      self.manager = manager
    }

    public convenience init(connectionManager: ConnectionManager) {
      self.init(connections: { [weak connectionManager] in connectionManager?.connections ?? [:] })
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
          let servers = withObservationTracking {
            self?.connections()
          } onChange: {
            continuation.yield()
            continuation.finish()
          }
          guard let self, let servers else { return }
          await reconcile(servers: servers)
          for await _ in stream { break }
        }
      }
    }

    public func stop() {
      observationTask?.cancel()
      observationTask = nil
    }

    /// Reconcile once against the current servers.
    public func reconcile() async {
      await reconcile(servers: connections())
    }

    private func reconcile(servers: [UUID: StoredConnection]) async {
      guard let manager else { return }
      let wanted = Dictionary(
        uniqueKeysWithValues: servers.map { ($0.key.uuidString, Self.displayName(for: $0.value)) })
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
      for domain in result.remove {
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
