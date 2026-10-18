import Foundation
import os

/// A ``DatabaseSuspensionController/RequestTime`` for a process with no
/// `UIApplication`, such as the File Provider extension: the time comes from
/// `ProcessInfo.performExpiringActivity(withReason:using:)`.
///
/// Such a process is treated as always in the background: the controller is
/// attached with `isInBackground: true` and suspended at once, so the
/// database writer is open only while counted work runs under one of these
/// activities. The system may suspend an extension whenever it is not
/// answering a call; with the writer suspended outside counted work, no write
/// lock is held at that moment (`0xDEAD10CC`).
///
/// How the activity is held: `performExpiringActivity` calls its block on a
/// background queue with `expired == false` and keeps the process from being
/// suspended until the block returns, so that block waits until the
/// controller hands the time back. When the system needs the time back it
/// calls the block again with `expired == true`; that call runs `onExpire` on
/// the main actor (the controller stops the work and suspends the writer)
/// before it lets the first block return. When no activity can be granted the
/// block is called only with `expired == true`, at once, and the work runs
/// with the writer suspended: its writes fail rather than hold a lock.
public enum ExpiringActivityTime {
  /// Starts an expiring activity; the system's is
  /// `ProcessInfo.performExpiringActivity(withReason:using:)`.
  public typealias Perform =
    @Sendable (_ reason: String, _ block: @escaping @Sendable (_ expired: Bool) -> Void) -> Void

  #if os(macOS)
    /// macOS has no expiring activities and never suspends the host tests
    /// that build this package there: the time is granted and never taken.
    public static let processInfo: Perform = { _, block in
      DispatchQueue.global().async { block(false) }
    }
  #else
    public static let processInfo: Perform = { reason, block in
      ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: block)
    }
  #endif

  /// The request-time function to attach the controller with.
  public static func request(
    reason: String = "Database work", perform: @escaping Perform = processInfo
  ) -> DatabaseSuspensionController.RequestTime {
    { onExpire in
      let activity = Activity()
      perform(reason) { expired in
        if expired {
          // Only an activity still held expires: one already handed back
          // must not call off the work of a later grant.
          guard activity.claimExpiry() else { return }
          Logger.persistence.notice("Expiring activity ended by the system")
          if Thread.isMainThread {
            MainActor.assumeIsolated { onExpire() }
          } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { onExpire() } }
          }
          activity.end()
        } else {
          activity.wait()
        }
      }
      return { activity.end() }
    }
  }

  /// One activity: the waiting block, released once.
  final class Activity: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    /// `ended`: handed back or expired; `expired`: the expiry was claimed.
    private let state = OSAllocatedUnfairLock(initialState: (ended: false, expired: false))

    func wait() {
      semaphore.wait()
    }

    /// Lets the waiting block return. Idempotent.
    func end() {
      let first = state.withLock { state -> Bool in
        defer { state.ended = true }
        return !state.ended
      }
      if first { semaphore.signal() }
    }

    /// Whether the expiry should run: only once, and only while the activity
    /// has not been handed back.
    func claimExpiry() -> Bool {
      state.withLock { state in
        guard !state.ended, !state.expired else { return false }
        state.expired = true
        return true
      }
    }
  }
}
