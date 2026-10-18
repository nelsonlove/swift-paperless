//
//  FileProviderSignaler.swift
//  AppShared
//
//  Tells the File Provider that a server's cached library may have changed, so
//  the Files app asks the extension for the changes.
//

#if canImport(FileProvider)

  import Foundation
  import os

  #if os(iOS) && !targetEnvironment(macCatalyst)
    import FileProvider
  #endif

  /// Signals each server's File Provider working set, at most once per
  /// ``interval`` per server.
  ///
  /// The first signal for a server is sent at once. Signals that arrive within
  /// the interval after it are folded into one trailing signal at the end of
  /// the interval, so a burst of writes costs the extension at most two change
  /// enumerations per interval (the leading one and the trailing one), and the
  /// last change of the burst is never lost.
  ///
  /// The system call only exists on iOS. On Mac Catalyst and on macOS (where
  /// the package is host-tested) the default ``send`` does nothing: the
  /// extension is not embedded there.
  @MainActor
  public final class FileProviderSignaler {
    /// What a signal does; the default asks the system to re-enumerate the
    /// server's working set.
    public typealias Send = @Sendable (UUID) async -> Void

    /// The process's signaler.
    public static let shared = FileProviderSignaler()

    public let interval: Duration
    private let send: Send
    private let clock = ContinuousClock()
    private var lastSent: [UUID: ContinuousClock.Instant] = [:]
    private var trailing: [UUID: Task<Void, Never>] = [:]

    public init(interval: Duration = .seconds(2), send: Send? = nil) {
      self.interval = interval
      self.send = send ?? Self.signalWorkingSet
    }

    /// Signal that `serverID`'s library may have changed.
    public func signal(serverID: UUID) {
      // A trailing signal is already due; it covers this change too.
      guard trailing[serverID] == nil else { return }
      if let last = lastSent[serverID], clock.now < last + interval {
        let deadline = last + interval
        trailing[serverID] = Task { [weak self] in
          try? await Task.sleep(until: deadline, clock: .continuous)
          self?.fire(serverID)
        }
      } else {
        fire(serverID)
      }
    }

    private func fire(_ serverID: UUID) {
      trailing[serverID] = nil
      lastSent[serverID] = clock.now
      let send = send
      Task { await send(serverID) }
    }

    /// Best effort: a failure is logged, and the next change signals again.
    public nonisolated static func signalWorkingSet(serverID: UUID) async {
      #if os(iOS) && !targetEnvironment(macCatalyst)
        let domain = NSFileProviderDomain(
          identifier: NSFileProviderDomainIdentifier(serverID.uuidString), displayName: "")
        guard let manager = NSFileProviderManager(for: domain) else {
          Logger.fileProvider.debug(
            "No File Provider manager for server \(serverID, privacy: .public); not signalled")
          return
        }
        do {
          try await manager.signalEnumerator(for: .workingSet)
        } catch {
          Logger.fileProvider.info(
            "Signalling the File Provider for server \(serverID, privacy: .public) failed: \(error)")
        }
      #endif
    }
  }

#endif
