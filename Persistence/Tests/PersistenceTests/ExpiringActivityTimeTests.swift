import Foundation
import Testing

@testable import Persistence

/// The time source the File Provider extension attaches the suspension
/// controller with.
@MainActor
@Suite("Expiring activity time")
struct ExpiringActivityTimeTests {
  /// Stands in for `performExpiringActivity`: runs the block on a background
  /// queue, and lets the test call it again with `expired == true`.
  final class FakeActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var block: (@Sendable (Bool) -> Void)?
    private var _returned = false
    var returned: Bool { lock.withLock { _returned } }

    var perform: ExpiringActivityTime.Perform {
      { [self] _, block in
        lock.withLock { self.block = block }
        DispatchQueue.global().async { [self] in
          block(false)
          lock.withLock { _returned = true }
        }
      }
    }

    func expire() {
      let block = lock.withLock { self.block }
      DispatchQueue.global().async { block?(true) }
    }
  }

  @MainActor
  final class Box {
    var expired = 0
    var calls: [String] = []
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test("The activity is held until the time is handed back")
  func heldUntilReleased() async {
    let fake = FakeActivity()
    let request = ExpiringActivityTime.request(perform: fake.perform)
    let release = request { Issue.record("no expiry expected") }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!fake.returned)
    release()
    await waitUntil { fake.returned }
    #expect(fake.returned)
    // Handing it back twice is harmless.
    release()
  }

  @Test("When the system takes the time back, onExpire runs first, then the activity ends")
  func expiryCallsOnExpire() async {
    let fake = FakeActivity()
    let request = ExpiringActivityTime.request(perform: fake.perform)
    let box = Box()
    _ = request { box.expired += 1 }
    fake.expire()
    await waitUntil { fake.returned }
    #expect(box.expired == 1)
    #expect(fake.returned)
  }

  @Test("An expiry after the time was handed back does nothing")
  func lateExpiryIgnored() async {
    let fake = FakeActivity()
    let request = ExpiringActivityTime.request(perform: fake.perform)
    let box = Box()
    let release = request { box.expired += 1 }
    release()
    await waitUntil { fake.returned }
    fake.expire()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(box.expired == 0)
  }

  @Test("Attached as a background process, the writer opens only while work runs")
  func controllerOpensWriterForWork() async {
    let fake = FakeActivity()
    let box = Box()
    let controller = DatabaseSuspensionController(
      suspend: { box.calls.append("suspend") }, resume: { box.calls.append("resume") })
    controller.attach(
      isInBackground: true, requestTime: ExpiringActivityTime.request(perform: fake.perform))
    controller.didEnterBackground()
    #expect(box.calls == ["suspend"])

    await controller.performBackgroundWork {
      #expect(box.calls == ["suspend", "resume"])
      #expect(!fake.returned)
    }
    #expect(box.calls == ["suspend", "resume", "suspend"])
    await waitUntil { fake.returned }
    #expect(fake.returned)
  }
}
