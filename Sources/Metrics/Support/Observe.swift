import Foundation
import Observation

/// Recursive observation helper: runs `tracked` under withObservationTracking
/// and, whenever any observable property it read changes, hops to the main
/// actor, runs `action`, then re-arms by observing again. The chain ends
/// naturally once `tracked` stops reading observable state (e.g. a weakly
/// captured owner has gone away).
@MainActor
func observeChanges(of tracked: @escaping () -> Void, perform action: @escaping @MainActor () -> Void) {
    withObservationTracking {
        tracked()
    } onChange: {
        Task { @MainActor in
            action()
            observeChanges(of: tracked, perform: action)
        }
    }
}
