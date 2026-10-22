import Foundation
import Observation

/// The agents whose session just finished a turn, each glowing green for `duration` from the moment its "New reply"
/// card is raised (`DesktopApplication.checkIslandEvents`), unless something waits on the user, whose yellow always wins
/// (`GlowAppearance.waitingOnUser`). What it reports changes only when a pulse starts and when it ends, and the end is
/// one scheduled wake-up rather than a poll, so a pulse redraws the HUDs twice and costs nothing in between.
@MainActor
@Observable
final class FinishPulse {
    static let shared = FinishPulse()
    /// About one breath at the working pace: long enough to catch from the corner of an eye, short enough to be news.
    static let duration: TimeInterval = 4

    /// The agents glowing green now, by the vendor their sessions and marks go by (`SessionCompletion.agentVendor`).
    private(set) var vendors: Set<String> = []
    /// When each agent's pulse ends; a turn finished during a pulse runs it on from then.
    @ObservationIgnored private var ends: [String: Date] = [:]
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored var clock: @MainActor () -> Date = { Date() }

    init() {}

    /// Starts, or runs on, the pulse of each agent that finished a turn.
    func finished(_ vendors: [String]) {
        guard !vendors.isEmpty else { return }
        let end = clock().addingTimeInterval(Self.duration)
        for vendor in vendors { ends[vendor] = end }
        settle()
    }

    /// Ends every pulse at once.
    func clear() {
        ends.removeAll()
        settle()
    }

    /// Drops the pulses that have ended and sleeps until the next one does.
    func settle() {
        let now = clock()
        ends = ends.filter { $0.value > now }
        let current = Set(ends.keys)
        if current != vendors { vendors = current }
        expiry?.cancel()
        guard let next = ends.values.min() else { return expiry = nil }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSince(now))))
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }
}
