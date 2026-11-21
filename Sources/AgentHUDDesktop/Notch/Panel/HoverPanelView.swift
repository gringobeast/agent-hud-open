import SwiftUI
import AgentHUDCore

/// Reports the panel's natural height so the island window can size itself to the content.
struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

/// The agents' blocks, a compact token chart and the local session summary, as its screen's panel layout arranges and
/// sets them: by default the quota rows, then the chart, then the sessions, at regular spacing with dividers between.
struct HoverPanelView: View {
    let store: UsageStore
    let onOpenStats: () -> Void
    var onOpenSettings: () -> Void = {}
    var additionalHUDControls: @MainActor () -> AnyView = { AnyView(EmptyView()) }
    /// Nil measures the natural layout; the visible panel gives its bounded height.
    var height: CGFloat? = nil
    var alert: IslandAlert? = nil
    var onOpenAlert: () -> Void = {}
    var onOpenAlertSession: () -> Void = {}
    var onOpenAlertUsage: () -> Void = {}
    var sessionNavigationFailed = false
    var onOpenListedSession: (String) -> Void = { _ in }
    var failedListedSessionID: String? = nil
    var onDecideAlert: (PermissionDecision) -> Void = { _ in }
    var waitingRequests: [PermissionRequest] = []
    /// The notch keeps its hardware clearance; a dock leaves room beside its parked logo strip instead.
    var insets = HoverPanelView.notchInsets
    static let notchInsets = EdgeInsets(top: 32, leading: 18, bottom: 14, trailing: 18)

    /// The narrowest the panel's content is laid out: an agent's own panel at its narrowest, inside the insets of a card
    /// that keeps no strip clear, 404 points. Beside the notch and on a top or bottom dock the whole panel's content is
    /// always wider; a dock on a side edge keeps its strip clear inside the panel, so there the panel is widened to it.
    static let narrowestContentWidth = CGFloat(PanelStyle(width: PanelStyle.widthRange.lowerBound).agentPanelWidth)
        - IslandRootView.detachedInsets.leading - IslandRootView.detachedInsets.trailing

    /// The whole panel's width with `insets`: its layout's `width`, or wider where those insets would leave the content
    /// narrower than `narrowestContentWidth`, which only a side dock's strip does. The type and the insets stay as they
    /// are, so no text is cut that the narrowest panel shows whole.
    static func width(_ width: CGFloat, insets: EdgeInsets) -> CGFloat {
        max(width, narrowestContentWidth + insets.leading + insets.trailing)
    }

    /// The row whose questions are open for answering here rather than in the agent.
    var answeringSessionID: String? = nil
    var onAnswerSession: (String?) -> Void = { _ in }
    /// Set on a dock that separates its agents: the panel is this one agent's, and shows nothing of the others.
    var focusVendor: String? = nil
    /// Whether a failed refresh is said above the panel's content; a picture of the panel leaves it out.
    var showsRefreshError = true
    /// The key of the screen whose panel this is, whose layout it draws (`PanelLayoutStore.effective(for:)`); nil draws
    /// the shared layout.
    var screen: String? = nil

    /// Whether something belongs to the agent this panel is for. Agents that share a mark share a panel.
    private func focused(_ vendor: String?) -> Bool {
        guard let focusVendor else { return true }
        return vendor.map { AgentArtwork.markKey($0) == AgentArtwork.markKey(focusVendor) } ?? false
    }

    /// Each vendor's rows, and no rows for a vendor that has only a notice, such as a signed-out client, whose block says it.
    var quotaGroups: [(vendor: String, rows: [AgentRow])] {
        (store.rowGroups + store.view.accountlessNotices.map { ($0.vendor, []) }).filter { focused($0.vendor) }
    }
    var billing: [APIBilling] { store.enabledBilling.filter { focused($0.vendor) } }
    private var consumers: [AgentDescriptor] { store.consumers.filter { focused($0.vendor) } }

    /// The models the token chart draws: those of the agents the layout names, and on an agent's own panel only that
    /// agent's among them, as the report holds them on this pass.
    private func tokenFilter(_ tokens: PanelTokenFilter) -> TokenModelFilter {
        TokenModelFilter(consumerIDs: store.panelTokenConsumers(tokens, vendor: focusVendor))
    }

    /// What makes the token chart another chart: its picker starts again from the layout's period when the panel's
    /// agent or the layout's tokens change.
    private struct TokenChartIdentity: Hashable {
        let vendor: String?
        let tokens: PanelTokenFilter
    }

    /// The tokens of the HUD the panel is drawn in. The charts and cards it shares with the statistics window are
    /// handed them.
    @Environment(\.hudTheme) var theme
    /// Above the draft bar and the footer, which keep their room whatever the layout's spacing.
    private let footerSpacing: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set on the panel's picture for an agent, whose session rows then name no session.
    @Environment(\.masksIdentity) var masksIdentity

    private var layout: PanelLayoutStore { store.settings.panelLayout }

    /// The panel under its screen's layout in effect, a draft included, its blocks in lines at the width the island
    /// gives the content. The layout decides what is shown, the Expanded panel's switches among it (`PanelSwitches`),
    /// and how. One agent's own panel sets every block across the whole line.
    private var plan: PanelLayoutPlan {
        let effective = layout.effective(for: screen)
        return PanelLayoutPlan(layout: effective, blocks: store.view.panelBlocks, contentWidth: Double(contentWidth(effective.style)),
                               pairs: focusVendor == nil)
    }

    /// The width the whole panel's content is laid out in under `style`: the width the island gives the panel
    /// (`width(_:insets:)`) inside its insets.
    func contentWidth(_ style: PanelStyle) -> CGFloat {
        Self.width(CGFloat(style.panelWidth), insets: insets) - insets.leading - insets.trailing
    }

    /// The sections that have something to show, in the layout's order.
    private func sections(_ plan: PanelLayoutPlan, blocks: [Block]) -> [PanelSection] {
        plan.sections.filter { section in
            switch section {
            case .blocks: !blocks.isEmpty
            case .tokens: store.isLoading || store.isIndexing || !consumers.isEmpty
            case .sessions: true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: footerSpacing) {
            if height != nil {
                ScrollView(.vertical) { measuredContent }
            } else {
                measuredContent
            }
            // An unsaved layout, this screen's unsaved HUD style, or the app's unsaved settings, is said above the
            // footer, outside the scrolling content, and counts in the height.
            VStack(alignment: .leading, spacing: footerSpacing) {
                if layout.hasDraft(on: screen) {
                    PanelDraftBar(layout: layout, screen: screen).transition(.opacity)
                }
                footer
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self,
                                       value: proxy.size.height + insets.top + insets.bottom + footerSpacing)
            })
        }
        .padding(insets)
        .frame(height: height, alignment: .top)
        .foregroundStyle(theme.text)
        .animation(reduceMotion ? nil : IslandAnimation.curve, value: layout.effective(for: screen))
        .animation(reduceMotion ? nil : IslandAnimation.curve, value: layout.draftScope(on: screen))
        .animation(reduceMotion ? nil : IslandAnimation.curve, value: layout.hasDraft(on: screen))
    }

    private var measuredContent: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
            })
    }

    private var content: some View {
        let plan = plan
        let lines = blockLines(plan)
        let blocks = lines.flatMap(\.blocks)
        let sections = sections(plan, blocks: blocks)
        let inlineAlert = alert.map { !$0.isSessionEvent } == true
        // A quota block names its agent; where none is drawn, the panel still has to say whose it is.
        let titled = focusVendor != nil && !(sections.contains(.blocks) && blocks.contains(where: \.isQuota))
        let error = showsRefreshError ? store.lastError : nil
        let hasHeader = error != nil || inlineAlert || titled
        let spacing = PanelSpacingMetrics(plan.style.spacing)
        let divider = plan.style.separators ? theme.divider : Color.clear
        return VStack(alignment: .leading, spacing: spacing.sections) {
            if let error {
                Text(L10n.text("刷新失败：", "Refresh failed: ") + error)
                    .font(.ui(11)).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let alert, !alert.isSessionEvent {
                IslandAlertInlineView(alert: alert, onOpen: onOpenAlert, onDecide: onDecideAlert,
                                      onOpenSession: onOpenAlertSession, onOpenUsage: onOpenAlertUsage,
                                      sessionNavigationFailed: sessionNavigationFailed,
                                      waitingRequests: waitingRequests).id(alert.id)
                    .padding(.bottom, 4)
            }
            if let focusVendor, titled {
                Text(focusVendor).font(.ui(13, .semibold))
            }
            ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                switch section {
                case .blocks:
                    blockList(lines, separated: index > 0, spacing: spacing, divider: divider)
                case .tokens:
                    TokenConsumptionChart(store: store, theme: theme, context: .island, modelFilter: tokenFilter(plan.tokens),
                                          period: plan.tokens.period, compact: true, onOpenStats: onOpenStats)
                        // The chart keeps its period as state, so another agent's panel, or another layout's tokens,
                        // is another chart; its models it is handed on every pass.
                        .id(TokenChartIdentity(vendor: focusVendor, tokens: plan.tokens))
                        .padding(.top, spacing.divided)
                        .topDivider(divider)
                case .sessions:
                    sessionLine(plan.sessions, hasAbove: index > 0 || hasHeader, spacing: spacing, divider: divider)
                }
            }
        }
        .environment(\.panelSpacing, spacing)
    }


    private var footer: some View {
        HStack {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help(L10n.text("设置", "Settings"))
            .accessibilityLabel(L10n.text("设置", "Settings"))
            Spacer()
            additionalHUDControls()
            Button {
                store.focusedSessionID = nil
                store.statsTab = .tokens
                onOpenStats()
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help(L10n.text("用量统计", "Usage statistics"))
            .accessibilityLabel(L10n.text("用量统计", "Usage statistics"))
        }
        .buttonStyle(.plain)
        .font(.ui(14))
        .foregroundStyle(theme.secondary)
        .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(theme.divider).frame(height: 1) }
    }
}
