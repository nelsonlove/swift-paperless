//
//  FreshReadTests.swift
//  FileProviderCore
//

import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct LatestWinsTests {
  @Test("An older read that finishes last never replaces a newer one")
  func olderLoses() {
    var holder = LatestWins<String>()
    let older = holder.begin()
    let newer = holder.begin()
    #expect(holder.offer("new", generation: newer) == "new")
    #expect(holder.offer("old", generation: older) == "new")
    #expect(holder.value == "new")
    #expect(holder.generation == newer)
  }

  @Test("Reads that finish in order each replace the last")
  func inOrder() {
    var holder = LatestWins<Int>()
    let first = holder.begin()
    #expect(holder.offer(1, generation: first) == 1)
    let second = holder.begin()
    #expect(holder.offer(2, generation: second) == 2)
    #expect(holder.value == 2)
  }
}

/// A read whose result the test hands over, so the order reads finish in is
/// the test's choice.
@MainActor
private final class Gate {
  var started = 0
  private var waiting: [Int: CheckedContinuation<String, any Error>] = [:]

  func read() async throws -> String {
    started += 1
    let number = started
    return try await withCheckedThrowingContinuation { waiting[number] = $0 }
  }

  func finish(_ number: Int, with value: String) {
    waiting.removeValue(forKey: number)?.resume(returning: value)
  }

  func fail(_ number: Int) {
    waiting.removeValue(forKey: number)?.resume(throwing: CancellationError())
  }

  func isWaiting(_ number: Int) -> Bool { waiting[number] != nil }
}

@MainActor
private func yieldUntil(_ condition: () -> Bool) async {
  for _ in 0..<1000 where !condition() {
    await Task.yield()
  }
}

@MainActor
@Suite
struct FreshReadTests {
  @Test("A read's result is returned and cached")
  func readIsCached() async throws {
    let reads = FreshRead<String>()
    let gate = Gate()
    let first = Task { try await reads.fresh { try await gate.read() } }
    await yieldUntil { gate.isWaiting(1) }
    #expect(gate.started == 1)
    gate.finish(1, with: "one")
    #expect(try await first.value == "one")
    #expect(reads.cached == "one")
    #expect(!reads.isReading)
  }

  @Test("A refresh that arrives during an older read waits for it, then reads again")
  func doesNotJoinAnOlderRead() async throws {
    let reads = FreshRead<String>()
    let gate = Gate()
    let first = Task { try await reads.fresh { try await gate.read() } }
    await yieldUntil { gate.isWaiting(1) }
    // Two refreshes that arrive while read 1 runs: both need a read that
    // starts after them, and share one.
    let second = Task { try await reads.fresh { try await gate.read() } }
    let third = Task { try await reads.fresh { try await gate.read() } }
    for _ in 0..<20 { await Task.yield() }
    #expect(gate.started == 1)

    gate.finish(1, with: "one")
    await yieldUntil { gate.isWaiting(2) }
    for _ in 0..<20 { await Task.yield() }
    #expect(gate.started == 2)
    gate.finish(2, with: "two")

    #expect(try await first.value == "one")
    #expect(try await second.value == "two")
    #expect(try await third.value == "two")
    #expect(reads.cached == "two")
    #expect(reads.cachedGeneration == 2)
  }

  @Test("cachedOrFresh joins the read in flight, then serves the cache")
  func cachedOrFresh() async throws {
    let reads = FreshRead<String>()
    let gate = Gate()
    let first = Task { try await reads.cachedOrFresh { try await gate.read() } }
    await yieldUntil { gate.isWaiting(1) }
    let joined = Task { try await reads.cachedOrFresh { try await gate.read() } }
    for _ in 0..<20 { await Task.yield() }
    gate.finish(1, with: "one")
    #expect(try await first.value == "one")
    #expect(try await joined.value == "one")
    #expect(try await reads.cachedOrFresh { try await gate.read() } == "one")
    #expect(gate.started == 1)
  }

  @Test("A failed read reaches its callers and leaves the cache as it was")
  func failureKeepsCache() async throws {
    let reads = FreshRead<String>()
    let gate = Gate()
    let first = Task { try await reads.fresh { try await gate.read() } }
    await yieldUntil { gate.isWaiting(1) }
    gate.finish(1, with: "one")
    _ = try await first.value

    let second = Task { try await reads.fresh { try await gate.read() } }
    await yieldUntil { gate.isWaiting(2) }
    gate.fail(2)
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(reads.cached == "one")
    #expect(!reads.isReading)
  }
}

@Suite
struct ExpiringValueTests {
  @Test("A value is served within its lifetime and not after")
  func expires() {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    var holder = ExpiringValue<String>(lifetime: 30)
    #expect(holder.value(at: start) == nil)
    holder.set("burst", at: start)
    #expect(holder.value(at: start.addingTimeInterval(29)) == "burst")
    #expect(holder.value(at: start.addingTimeInterval(30)) == nil)
    #expect(holder.value(at: start.addingTimeInterval(3600)) == nil)
    // A clock set back does not make an old value young.
    #expect(holder.value(at: start.addingTimeInterval(-1)) == nil)
    holder.set(nil, at: start)
    #expect(holder.value(at: start) == nil)
  }
}
