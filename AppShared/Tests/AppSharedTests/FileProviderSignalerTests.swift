#if canImport(FileProvider)

  import Foundation
  import Testing

  @testable import AppShared

  /// Collects what a signaler sent, across the `@Sendable` boundary.
  private actor Sent {
    private(set) var ids: [UUID] = []
    func append(_ id: UUID) { ids.append(id) }
  }

  @MainActor
  @Suite
  struct FileProviderSignalerTests {
    @Test("The first signal is sent at once and a burst after it becomes one trailing signal")
    func burstCoalesces() async throws {
      let sent = Sent()
      let signaler = FileProviderSignaler(interval: .milliseconds(300)) { await sent.append($0) }
      let server = UUID()

      signaler.signal(serverID: server)
      try await eventually { await sent.ids.count == 1 }
      signaler.signal(serverID: server)
      signaler.signal(serverID: server)
      signaler.signal(serverID: server)
      #expect(await sent.ids.count == 1)

      try await eventually { await sent.ids.count == 2 }
      try await Task.sleep(for: .milliseconds(400))
      #expect(await sent.ids == [server, server])
    }

    @Test("Servers are coalesced separately")
    func serversAreIndependent() async throws {
      let sent = Sent()
      let signaler = FileProviderSignaler(interval: .seconds(10)) { await sent.append($0) }
      let first = UUID()
      let second = UUID()

      signaler.signal(serverID: first)
      signaler.signal(serverID: second)

      try await eventually { await sent.ids.count == 2 }
      #expect(Set(await sent.ids) == [first, second])
    }

    @Test("A signal after the interval has passed is sent at once")
    func signalAfterIntervalIsImmediate() async throws {
      let sent = Sent()
      let signaler = FileProviderSignaler(interval: .milliseconds(50)) { await sent.append($0) }
      let server = UUID()

      signaler.signal(serverID: server)
      try await eventually { await sent.ids.count == 1 }
      try await Task.sleep(for: .milliseconds(100))
      signaler.signal(serverID: server)
      try await eventually { await sent.ids.count == 2 }
    }
  }

  /// Polls `condition` until it holds; records an issue after five seconds.
  @MainActor
  func eventually(
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while await !condition() {
      if ContinuousClock.now > deadline {
        Issue.record("timed out waiting for condition", sourceLocation: sourceLocation)
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

#endif
