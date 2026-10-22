import AgentHUDCore
import Foundation

/// Which arrivals on the waiting list ring the waiting sound: one ring for a request that joins it while the app
/// watches, never a second for the same id, even when its client's reading drops it and brings it back. A request the
/// app found already waiting when it started rings nothing, and neither does one that arrives while it is paused.
struct RequestChime {
    /// How long after launch a request counts as found rather than arrived: the native clients' first readings fill the
    /// list with what already waited before the app started, stamped with the time they were read.
    static let settling: TimeInterval = 10

    let startedAt: Date
    /// Every request id seen on the list, rung for or not.
    private var heard: Set<String> = []

    init(startedAt: Date) { self.startedAt = startedAt }

    /// Whether the waiting list as it is now holds a request worth ringing for. Every id on it is heard either way, so
    /// one that arrived silently, settling or paused, stays silent.
    mutating func rings(for pending: [PermissionRequest], now: Date, paused: Bool) -> Bool {
        let arrived = pending.filter { heard.insert($0.id).inserted }
        guard !paused, now.timeIntervalSince(startedAt) >= Self.settling else { return false }
        return arrived.contains { $0.at >= startedAt }
    }
}
