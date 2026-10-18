import Foundation
import Persistence
import Testing

@testable import AppShared

@MainActor
@Suite
struct AppStackTests {
  @Test("The connection manager reads the servers from the stack's database")
  func connectionManagerSharesDatabase() throws {
    let serverID = UUID()
    let stack = AppStack(database: try Database.seeded(serverID: serverID))

    #expect(stack.connectionManager.connections.keys.contains(serverID))
  }

  @Test("The registry hands out one session per server")
  func oneSessionPerServer() throws {
    let serverID = UUID()
    let stack = AppStack(database: try Database.seeded(serverID: serverID))

    let first = stack.sessionRegistry.session(for: serverID)
    #expect(stack.sessionRegistry.session(for: serverID) === first)
    #expect(stack.sessionRegistry.session(for: UUID()) !== first)
  }

  @Test("The registry reports a removed server, for the files that live outside the database")
  func serverRemovalIsReported() async throws {
    let serverID = UUID()
    let stack = AppStack(database: try Database.seeded(serverID: serverID))
    var removed: Set<UUID> = []
    stack.sessionRegistry.onServersRemoved = { removed = $0 }
    stack.sessionRegistry.start()

    _ = try stack.database.deleteConnection(id: serverID)

    try await waitUntil({ removed == [serverID] }, "the removal was never reported")
  }

  @Test("Without a content store the stack caches no files and the reclaim is harmless")
  func noStoreNoFiles() async throws {
    let stack = AppStack(database: try Database.seeded())

    #expect(stack.sessionRegistry.contentReclaimer?.store == nil)
    let report = await stack.contentReclaimer.run(reason: .manual)
    #expect(report.removedFiles == 0)
    #expect(!report.walked)
  }

  @Test("A stack built for the File Provider extension leaves open sync steps alone")
  func extensionLeavesSyncStepsOpen() async throws {
    let database = try Database.seeded()
    let started = Date(timeIntervalSinceNow: -60)
    _ = try await database.beginSyncStep(
      runID: UUID(), serverID: nil, trigger: "test", step: "sync", at: started)

    _ = AppStack(database: database, role: .fileProviderExtension)
    // Give a launch task, if one were started, the time to run.
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await database.syncRuns().allSatisfy(\.isOpen))

    // The app's stack closes it, so the wait above was long enough to see it.
    let app = AppStack(database: database)
    _ = app
    let deadline = ContinuousClock.now + .seconds(5)
    var closed = false
    while !closed, ContinuousClock.now < deadline {
      closed = try await database.syncRuns().allSatisfy { !$0.isOpen }
      if !closed { try await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(closed, "the app stack never closed the open step")
  }
}
