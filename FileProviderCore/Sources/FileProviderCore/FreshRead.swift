//
//  FreshRead.swift
//  FileProviderCore
//

import Foundation

/// Holds the newest of the values that reads produce, when the reads can
/// finish out of order: each read takes a generation when it starts, and a
/// result is kept only if no read that started later has delivered already.
///
/// The File Provider extension rereads the library from the database; an
/// older read that finishes after a newer one must not replace it, or the
/// next change page would report the newer read's items as deleted.
public struct LatestWins<Value> {
  /// The value of the newest read that has delivered, if any.
  public private(set) var value: Value?
  /// The generation of ``value``; 0 when there is none.
  public private(set) var generation: UInt64 = 0
  /// The generation the last ``begin()`` handed out.
  public private(set) var issued: UInt64 = 0

  public init() {}

  /// A new generation for a read that starts now. Later calls return larger
  /// numbers.
  public mutating func begin() -> UInt64 {
    issued += 1
    return issued
  }

  /// Offers the result of the read that started with `generation`, and
  /// returns the value now held: `value` when no later read has delivered,
  /// else the later read's value.
  @discardableResult
  public mutating func offer(_ value: Value, generation: UInt64) -> Value {
    // Generations start at 1, so the first result is always taken.
    if generation > self.generation {
      self.value = value
      self.generation = generation
    }
    return self.value ?? value
  }
}

extension LatestWins: Sendable where Value: Sendable {}

/// A single-flight read that only ever hands out a result at least as new as
/// the request, and never goes back in time.
///
/// ``fresh(_:)`` joins the read in flight only if that read started after the
/// call began; a read that started earlier may have read the database before
/// the change the caller was told about, so the caller waits for it to end and
/// then starts (or joins) a later one. Results go through ``LatestWins``, so a
/// slow read can never replace a newer one.
///
/// Main-actor state, so claiming the slot never suspends: the check for a read
/// in flight and the claim of a new one run without an `await` in between,
/// the same invariant as `Common.TaskSlot`.
@MainActor
public final class FreshRead<Value: Sendable> {
  private var inFlight: (generation: UInt64, task: Task<Value, any Error>)?
  private var latest = LatestWins<Value>()

  public init() {}

  /// The value of the newest read that has delivered, if any.
  public var cached: Value? { latest.value }

  /// The generation of ``cached``; 0 when there is none.
  public var cachedGeneration: UInt64 { latest.generation }

  /// Whether a read is in flight.
  public var isReading: Bool { inFlight != nil }

  /// A value from a read that started no earlier than this call, or a newer
  /// one. Joins such a read in flight, else waits out an older one and starts
  /// a new read with `read`.
  ///
  /// The read is unstructured and shared: cancelling a caller does not cancel
  /// it. A read's error reaches the callers that joined it; an older read's
  /// error does not reach a caller that only waited for it to end.
  public func fresh(_ read: @escaping @MainActor () async throws -> Value) async throws -> Value {
    try await freshEntry(read).value
  }

  /// ``fresh(_:)`` with the generation of the value it returns, which is
  /// ``cachedGeneration`` when it returns.
  public func freshEntry(_ read: @escaping @MainActor () async throws -> Value) async throws
    -> (value: Value, generation: UInt64)
  {
    // Any read with this generation or a later one starts after this call.
    let wanted = latest.issued + 1
    while true {
      if let flight = inFlight {
        if flight.generation >= wanted {
          return try await finish(flight)
        }
        // Older than the request: wait for it, keep its result if it is the
        // newest, and look again.
        _ = try? await finish(flight)
        continue
      }
      let generation = latest.begin()
      let task = Task { @MainActor in try await read() }
      let flight = (generation: generation, task: task)
      inFlight = flight
      return try await finish(flight)
    }
  }

  /// The cached value; when there is none, the read in flight, else a new
  /// read. Any read will do here, so an older one is joined.
  public func cachedOrFresh(_ read: @escaping @MainActor () async throws -> Value) async throws
    -> Value
  {
    if let cached = latest.value { return cached }
    if let flight = inFlight { return try await finish(flight).value }
    return try await fresh(read)
  }

  /// Awaits `flight`, empties the slot if it still holds it, and returns the
  /// newest value held after offering the flight's result, with its
  /// generation.
  private func finish(_ flight: (generation: UInt64, task: Task<Value, any Error>)) async throws
    -> (value: Value, generation: UInt64)
  {
    defer {
      if inFlight?.generation == flight.generation { inFlight = nil }
    }
    let value = try await flight.task.value
    let held = latest.offer(value, generation: flight.generation)
    return (held, latest.generation)
  }
}

/// A value that is only good for a while: ``value(at:)`` answers `nil` once
/// `lifetime` has passed since it was set.
///
/// The extension keeps the library one burst of change pages works from in
/// one, so a signal that comes long after a burst stopped half-way (the
/// enumerator invalidated, a page never asked for) never reports from that
/// old library.
public struct ExpiringValue<Value> {
  public let lifetime: TimeInterval
  private var stored: (value: Value, setAt: Date)?

  public init(lifetime: TimeInterval) {
    self.lifetime = lifetime
  }

  /// The value, unless none is set or it is older than ``lifetime`` at `now`
  /// (or set in the future of `now`, after a clock change).
  public func value(at now: Date) -> Value? {
    guard let stored else { return nil }
    let age = now.timeIntervalSince(stored.setAt)
    guard age >= 0, age < lifetime else { return nil }
    return stored.value
  }

  /// Sets `value` as of `now`, or clears it with `nil`.
  public mutating func set(_ value: Value?, at now: Date) {
    stored = value.map { ($0, now) }
  }
}

extension ExpiringValue: Sendable where Value: Sendable {}

/// What one burst of change pages keeps between its pages, for at most
/// `lifetime`: the library the pages diff against, with the generation of the
/// read that produced it (``LatestWins/generation``), and the change state as
/// last saved, so a page neither rereads nor decodes the state.
///
/// The library is handed out only while no newer read has been cached
/// (`newestGeneration`): a lookup or an enumeration may have read the library
/// after the burst started, and a change page must never report from a
/// library older than one the system was already given items from. The state
/// stays good either way: it is what was saved.
public struct ChangeBurst<Library> {
  public struct Entry {
    public var library: Library
    public var generation: UInt64
    public var state: ChangeState
  }

  private var stored: ExpiringValue<Entry>

  public init(lifetime: TimeInterval) {
    stored = ExpiringValue(lifetime: lifetime)
  }

  /// The burst's library and its generation, unless there is no burst, it
  /// expired, or its library is older than `newestGeneration`.
  public func library(at now: Date, newestGeneration: UInt64) -> (
    library: Library, generation: UInt64
  )? {
    guard let entry = stored.value(at: now), entry.generation >= newestGeneration else {
      return nil
    }
    return (entry.library, entry.generation)
  }

  /// The change state the burst last saved, unless there is no burst or it
  /// expired.
  public func state(at now: Date) -> ChangeState? {
    stored.value(at: now)?.state
  }

  /// Keeps `library` (from the read of `generation`) and `state` for the
  /// next page, as of `now`.
  public mutating func keep(
    library: Library, generation: UInt64, state: ChangeState, at now: Date
  ) {
    stored.set(Entry(library: library, generation: generation, state: state), at: now)
  }

  /// Ends the burst.
  public mutating func end(at now: Date) {
    stored.set(nil, at: now)
  }
}

extension ChangeBurst.Entry: Sendable where Library: Sendable {}
extension ChangeBurst: Sendable where Library: Sendable {}
