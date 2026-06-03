import Observation
import XCTest
@testable import mumble_macos

/// Pins the contract every AppKit controller relies on: tracked render,
/// per-runloop-turn coalescing of mutation bursts, re-arm after render,
/// and invalidate() dropping in-flight work. The burst case is the
/// handshake invariant in miniature — 100 mutations must produce one
/// render, not 100.
/// File-scope because the @Observable macro's generated conformance
/// extension can't reference a type nested `private` inside the test class.
@Observable @MainActor
private final class TrackerTestModel {
    var value = 0
    var other = 0
}

@MainActor
final class ObservationTrackerTests: XCTestCase {
    private typealias Model = TrackerTestModel

    /// Pumps the main dispatch queue enough turns for the tracker's
    /// Task-hop + DispatchQueue-coalesce pipeline to settle.
    private func drainMainQueue(turns: Int = 8) async {
        for _ in 0..<turns {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { c.resume() }
            }
        }
    }

    func test_startRendersOnceImmediately() {
        let model = Model()
        var renders = 0
        let tracker = ObservationTracker {
            renders += 1
            _ = model.value
        }
        XCTAssertEqual(renders, 0, "init must not render")
        tracker.start()
        XCTAssertEqual(renders, 1)
        tracker.invalidate()
    }

    func test_burstOfMutationsCoalescesToOneRender() async {
        let model = Model()
        var renders = 0
        let tracker = ObservationTracker {
            renders += 1
            _ = model.value
        }
        tracker.start()
        for i in 1...100 { model.value = i }
        await drainMainQueue()
        XCTAssertEqual(renders, 2, "100 synchronous mutations → exactly one re-render")
        tracker.invalidate()
    }

    func test_reArmsAfterEachRender() async {
        let model = Model()
        var renders = 0
        let tracker = ObservationTracker {
            renders += 1
            _ = model.value
        }
        tracker.start()
        model.value = 1
        await drainMainQueue()
        XCTAssertEqual(renders, 2)
        model.value = 2
        await drainMainQueue()
        XCTAssertEqual(renders, 3, "tracking must survive across render cycles")
        tracker.invalidate()
    }

    func test_untrackedPropertyDoesNotRender() async {
        let model = Model()
        var renders = 0
        let tracker = ObservationTracker {
            renders += 1
            _ = model.value   // reads value, never other
        }
        tracker.start()
        model.other = 99
        await drainMainQueue()
        XCTAssertEqual(renders, 1, "mutating an unread property must not wake the tracker")
        tracker.invalidate()
    }

    func test_invalidateStopsFutureRenders() async {
        let model = Model()
        var renders = 0
        let tracker = ObservationTracker {
            renders += 1
            _ = model.value
        }
        tracker.start()
        tracker.invalidate()
        model.value = 1
        await drainMainQueue()
        XCTAssertEqual(renders, 1)
    }

    func test_invalidateDropsInFlightScheduledRender() async {
        let model = Model()
        var renders = 0
        let tracker = ObservationTracker {
            renders += 1
            _ = model.value
        }
        tracker.start()
        model.value = 1          // schedules a render…
        tracker.invalidate()     // …which must be dropped
        await drainMainQueue()
        XCTAssertEqual(renders, 1)
    }
}
