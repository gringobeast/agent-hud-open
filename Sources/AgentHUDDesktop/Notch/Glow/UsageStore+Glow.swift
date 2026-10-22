import AgentHUDCore

@MainActor
public extension UsageStore {
    /// The glow of every agent: drawn only while a session waits on the user, in one warm yellow
    /// (`GlowAppearance.waitingOnUser`), at the working pace while any session is in flight; or, with nothing waiting,
    /// green for a moment after a session finished a turn (`FinishPulse`).
    /// - screen: which display's glow to resolve; nothing asks for the default one.
    func glowAppearance(light: Bool, on screen: String? = nil) -> GlowAppearance {
        glowAppearance(on: screen, anyAgentActive: hasLiveSession, waiting: isWaitingOnUser, finished: hasJustFinished)
    }

    /// Whether any agent's session finished a turn moments ago, its green pulse still running (`FinishPulse`).
    var hasJustFinished: Bool { !FinishPulse.shared.vendors.isEmpty }

    /// Whether anything waits on the user: a session waiting for an approval or an answer, its client's own word
    /// included (`ReportView` folds `PermissionRequests.shared` into each session's phase), or a permission request on
    /// the HUD whose session the report does not list yet or whose live status is off.
    var isWaitingOnUser: Bool {
        !PermissionRequests.shared.pending.isEmpty || view.sessions.contains { $0.phase.state == .waitingForApproval }
    }

    /// A glow drawn at the given pace, shown only while something waits on the user, as a screen whose layout lists
    /// its agents draws it (`ScreenAgents`), under that screen's glow settings with its style draft drawn over them.
    /// Neither the quota's levels nor a light screen colour it: it is one yellow, or one green, everywhere.
    /// - waiting: whether anything of the agents the screen shows waits on the user; hidden otherwise.
    /// - finished: whether one of the agents the screen shows finished a turn moments ago; yellow wins over it.
    internal func glowAppearance(on screen: String?, anyAgentActive: Bool, waiting: Bool,
                                 finished: Bool = false) -> GlowAppearance {
        let appearance = GlowAppearance.waitingOnUser(
            waiting,
            finished: finished,
            anyAgentActive: anyAgentActive,
            glow: settings.effectiveGlow(on: screen)
        )
        guard glowHidden else { return appearance }
        return appearance.suppressed()
    }
}
