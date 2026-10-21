import AgentHUDCore

@MainActor
public extension UsageStore {
    /// The glow of every agent: drawn only while a session waits on the user, in one warm yellow
    /// (`GlowAppearance.waitingOnUser`), at the working pace while any session is in flight.
    /// - screen: which display's glow to resolve; nothing asks for the default one.
    func glowAppearance(light: Bool, on screen: String? = nil) -> GlowAppearance {
        glowAppearance(on: screen, anyAgentActive: hasLiveSession, waiting: isWaitingOnUser)
    }

    /// Whether anything waits on the user: a session waiting for an approval or an answer, its client's own word
    /// included (`ReportView` folds `PermissionRequests.shared` into each session's phase), or a permission request on
    /// the HUD whose session the report does not list yet or whose live status is off.
    var isWaitingOnUser: Bool {
        !PermissionRequests.shared.pending.isEmpty || view.sessions.contains { $0.phase.state == .waitingForApproval }
    }

    /// A glow drawn at the given pace, shown only while something waits on the user, as a screen whose layout lists
    /// its agents draws it (`ScreenAgents`), under that screen's glow settings with its style draft drawn over them.
    /// Neither the quota's levels nor a light screen colour it: it is one yellow everywhere.
    /// - waiting: whether anything of the agents the screen shows waits on the user; hidden otherwise.
    internal func glowAppearance(on screen: String?, anyAgentActive: Bool, waiting: Bool) -> GlowAppearance {
        let appearance = GlowAppearance.waitingOnUser(
            waiting,
            anyAgentActive: anyAgentActive,
            glow: settings.effectiveGlow(on: screen)
        )
        guard glowHidden else { return appearance }
        return appearance.suppressed()
    }
}
