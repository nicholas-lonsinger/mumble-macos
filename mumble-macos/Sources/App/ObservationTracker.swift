import Foundation
import Observation

/// Re-arming bridge from `@Observable` models to AppKit controllers.
///
/// AppKit on macOS 26 has no automatic observation tracking (that's a
/// UIKit-only feature), so controllers that render from `@Observable`
/// models own one of these. `render` runs inside `withObservationTracking`,
/// which means exactly the properties it reads are tracked — a controller
/// whose render never touches `client.channels` is never woken when
/// channels mutate. That selective tracking is load-bearing for the
/// handshake invariant: while disconnected/handshaking, renders read only
/// `client.state`, so the 700+ ChannelState/UserState mutations between
/// TLS and ServerSync trigger nothing.
///
/// Change delivery is coalesced: any number of tracked mutations within a
/// runloop turn produce one `render` on the next turn, which re-arms
/// tracking against whatever it read. `render` must capture its controller
/// weakly (the controller owns the tracker).
@MainActor
final class ObservationTracker {
    private let render: @MainActor () -> Void
    private var scheduled = false
    private var invalidated = false

    init(render: @escaping @MainActor () -> Void) {
        self.render = render
    }

    /// Runs `render` once immediately and arms tracking. Call after the
    /// controller's views exist (e.g. end of `viewDidLoad`).
    func start() {
        renderAndArm()
    }

    /// Stops tracking. Idempotent; drops any in-flight scheduled render.
    func invalidate() {
        invalidated = true
    }

    private func renderAndArm() {
        guard !invalidated else { return }
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            // Fires synchronously inside the first mutation of any tracked
            // property, on the mutating context (MainActor for all our
            // models). Hop once so we never re-enter the still-mutating
            // store, then coalesce.
            Task { @MainActor [weak self] in
                self?.schedule()
            }
        }
    }

    private func schedule() {
        guard !invalidated, !scheduled else { return }
        scheduled = true
        // Coalesce: the first mutation in a turn arms this block; later
        // mutations hit the `scheduled` guard (and tracking is one-shot
        // anyway). Re-arm happens after `render` so the next tracking
        // cycle registers against fresh reads.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.invalidated else { return }
                self.scheduled = false
                self.renderAndArm()
            }
        }
    }
}
