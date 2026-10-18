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
    @Test("A burst of signals becomes the first one plus one trailing signal")
    func burstCoalesces() async throws {
      let sent = Sent()
      let signaler = FileProviderSignaler(interval: .milliseconds(300)) { await sent.append($0) }
      let server = UUID()

      // No suspension between the calls, so all of them land inside one interval
      // however slow the host is.
      signaler.signal(serverID: server)
      signaler.signal(serverID: server)
      signaler.signal(serverID: server)
      signaler.signal(serverID: server)

      try await waitUntil { await sent.ids.count == 2 }
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

      try await waitUntil { await sent.ids.count == 2 }
      #expect(Set(await sent.ids) == [first, second])
    }

    @Test("A signal after the interval has passed is sent at once")
    func signalAfterIntervalIsImmediate() async throws {
      let sent = Sent()
      let signaler = FileProviderSignaler(interval: .milliseconds(50)) { await sent.append($0) }
      let server = UUID()

      signaler.signal(serverID: server)
      try await waitUntil { await sent.ids.count == 1 }
      try await Task.sleep(for: .milliseconds(100))
      signaler.signal(serverID: server)
      try await waitUntil { await sent.ids.count == 2 }
    }
  }

#endif
