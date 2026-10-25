import AppKit
import AgentHUDCore

struct MenuActions {
    var toggleGlow: () -> Void = {}
    var openSettings: () -> Void = {}
    var openStats: () -> Void = {}
    var quit: () -> Void = {}
}

/// Menu bar item (notch silhouette + highest % used) and its menu, a panel the app draws in the look of the screen the
/// menu bar is on (`StatusMenuPanel`).
///
/// Both follow the agents a HUD shows at rest under its layout's list (`ScreenAgents`), a draft included, as the HUD
/// draws it now. The item has one figure and one set of colours for every menu bar, so they follow the HUD of the main
/// display, the first the system lists, which has the only menu bar while Displays have separate Spaces is off. The
/// menu follows the HUD of the screen whose menu bar it opens from, as its look does, and reads it as it opens.
@MainActor
final class StatusItemController: NSObject {
    /// A display as the menu bar follows its HUD: its key, under which its placement and its own layout are kept, and
    /// whether it has a notch, which gives the placement its HUD draws while it keeps none of its own.
    struct Screen: Equatable {
        let key: String
        let hasNotch: Bool

        init(key: String, hasNotch: Bool) {
            self.key = key
            self.hasNotch = hasNotch
        }

        @MainActor
        init(_ screen: NSScreen) {
            self.init(key: ScreenIdentity.key(for: screen), hasNotch: ScreenIdentity.hasNotch(screen))
        }

        /// The main display, the first the system lists, whose HUD the item's figure and colours follow; nil while no
        /// display is attached.
        @MainActor
        static var primary: Screen? { NSScreen.screens.first.map(Screen.init) }
    }

    /// What the item shows: the colours of a HUD's glow, from the levels of its parts, and its figure, the most used
    /// window among the agents it shows whose readings show a level.
    struct Figure: Equatable {
        let levels: [StatusLevel]
        let usedPct: Double?
    }

    private let item: NSStatusItem
    private let store: UsageStore
    private let settings: SettingsStore
    private let additionalMenuItems: () -> [NSMenuItem]
    var actions = MenuActions()
    /// The open menu, made at its first opening.
    private(set) var panel: StatusMenuPanel?
    /// What closes the open menu: clicks elsewhere, the app resigning, a change of displays or Space.
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// The window that had the keys before the menu took them, the app's own non-activating panels among them, such as
    /// the island while its question field takes the keyboard, which gets them back when it closes.
    private weak var previousKeyWindow: NSWindow?
    /// The view in that window that had them, the field being typed in rather than the field editor typing for it, and
    /// where its caret stood: a panel that hands the keyboard back ends the typing as the menu takes it.
    private weak var previousResponder: NSView?
    private var previousSelection: NSRange?
    /// The event that closed the menu last, so the click on the status item that closed it does not open it again.
    private var dismissingEvent: TimeInterval?
    /// What reads the item's figure again when the displays change, which can make another display the main one.
    private var displayObserver: NSObjectProtocol?

    init(store: UsageStore, settings: SettingsStore, additionalMenuItems: @escaping () -> [NSMenuItem] = { [] }) {
        self.store = store
        self.settings = settings
        self.additionalMenuItems = additionalMenuItems
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggleMenu)
            // A menu opens as the button is pressed, not as it is let go.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        refreshButton()
        trackChanges({ [weak self] in
            guard let self else { return }
            _ = self.store.rows
            _ = self.store.pausedUntil
            _ = self.store.isAccessAllowed
            _ = self.settings.effectiveSettings.showMenuBarIcon
            _ = self.settings.settings.language
            // The main display's layout and mode, a draft of either included, and what its HUD shows of them.
            _ = self.figure(on: .primary)
        }, onChange: { [weak self] in
            self?.refreshButton()
        })
        // A turn later, so that the HUDs have taken the change first and every display is known by its key again.
        let displaysChanged: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refreshButton() }
        }
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: displaysChanged)
    }

    // MARK: Button

    /// Whether the item is in the menu bar now.
    var showsItem: Bool { item.isVisible }

    /// What the item writes beside its icon now, as `refreshButton()` last wrote it: its figure, with a space before it.
    var title: String? { item.button?.attributedTitle.string }

    /// Shows or hides the item as the app draws its settings, an agent's unsaved draft of them included: a draft that hides
    /// it leaves its Save and Discard in the HUD's panel (`PanelLayoutStore.hasDraft(on:)`).
    func refreshButton() {
        item.isVisible = !store.isAccessAllowed || settings.effectiveSettings.showMenuBarIcon
        if !item.isVisible { closeMenu() }
        guard let button = item.button else { return }
        let figure = figure(on: .primary)
        let stops = store.isPaused || !store.isAccessAllowed ? GlowGradient.idleStops
            : GlowGradient.stops(levels: figure.levels, light: SystemAppearance.isLight)
        button.image = StatusIconRenderer.image(stops: stops)
        let title = store.isAccessAllowed ? (figure.usedPct.map { " \(TokenFormat.percent($0))" } ?? " —") : " —"
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .baselineOffset: 0,
        ])
        button.toolTip = AppResources.applicationName + L10n.text(" · 最高每周额度", " · highest weekly usage")
    }

    /// What the HUD of `screen` shows of the agents at rest: the agents the layout it draws now lists, a draft included,
    /// resolved against what it would show in the mode it draws now, a style draft included (`ScreenAgents`). Every
    /// agent for no display.
    func agents(on screen: Screen?) -> ScreenAgents {
        guard let screen else { return ScreenAgents(store: store, listed: [], mode: .notch) }
        return ScreenAgents(store: store, listed: settings.panelLayout.effective(for: screen.key).hud.agents,
                            mode: settings.effectivePlacement(on: screen.key, hasNotch: screen.hasNotch).mode)
    }

    /// What the item shows for the HUD of `screen`: its glow's colours, as that HUD draws them at rest, and the most used
    /// weekly window of every agent (`ReportView.maxWeeklyUsedPct`), whichever agents that HUD shows.
    func figure(on screen: Screen?) -> Figure {
        let agents = agents(on: screen)
        return Figure(levels: agents.glowSegments.map(\.level), usedPct: store.view.maxWeeklyUsedPct)
    }

    // MARK: Opening and closing

    /// Whether the menu is open; false from the moment it starts closing, so that its panel losing the keys as it goes
    /// does not close it twice.
    private(set) var isMenuOpen = false

    /// A click on the status item opens the menu, and a second one closes it. A press that is not the click that just
    /// closed it opens it, VoiceOver's, Full Keyboard Access's or a script's after Escape among them.
    @objc func toggleMenu() {
        if isMenuOpen {
            closeMenu()
        } else if !Self.isClosingClick(NSApp.currentEvent, closedAt: dismissingEvent, buttonWindow: item.button?.window) {
            openMenu()
        }
    }

    /// Whether `event` is the click on the status item that closed the menu just now, at `timestamp`: a left or right
    /// mouse-down in the button's window at that moment. Any other event, a key that closed the menu and is still the
    /// app's current event as VoiceOver presses the button included, is not.
    static func isClosingClick(_ event: NSEvent?, closedAt timestamp: TimeInterval?, buttonWindow: NSWindow?) -> Bool {
        guard let event, let timestamp, let buttonWindow, buttonWindow.windowNumber > 0,
              event.type == .leftMouseDown || event.type == .rightMouseDown else { return false }
        return event.timestamp == timestamp && event.windowNumber == buttonWindow.windowNumber
    }

    /// Opens the menu under the status item, on the screen of its menu bar, in that screen's look and with the agents
    /// that screen's HUD shows.
    func openMenu() {
        guard !isMenuOpen else { return }
        Task { await store.refreshAccounts() }
        let screen = item.button?.window?.screen ?? NSScreen.main
        let look = Self.menuLook(on: screen)
        let panel = self.panel ?? makePanel(look: look)
        panel.apply(look: look)
        let entries = menuEntries(on: screen.map(Screen.init))
        let size = StatusMenuLayout.size(for: entries)
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let anchor = item.button?.window?.frame ?? CGRect(x: visible.maxX - size.width, y: visible.maxY, width: 0, height: 0)
        rememberKeys(of: NSApp.keyWindow)
        isMenuOpen = true
        panel.show(entries, in: StatusMenuLayout.frame(size: size, below: anchor, in: visible))
        startWatchingForDismissal()
        // The button stays pressed while its menu is open; it lets go of its highlight as the mouse goes up, so the
        // highlight is set a turn later.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isMenuOpen else { return }
            self.item.button?.highlight(true)
        }
    }

    /// Closes the menu, without choosing anything, and gives the keys back to the window that had them, whether or not
    /// the app is active, unless `returningKeys` is false: they went elsewhere already, to the app clicked into or the
    /// window that took them.
    func closeMenu(returningKeys: Bool = true) {
        guard isMenuOpen, let panel else { return }
        isMenuOpen = false
        dismissingEvent = NSApp.currentEvent?.timestamp
        stopWatchingForDismissal()
        panel.hide()
        item.button?.highlight(false)
        if returningKeys { returnKeys() }
        previousKeyWindow = nil
        previousResponder = nil
        previousSelection = nil
    }

    private func rememberKeys(of window: NSWindow?) {
        guard let window, window !== panel else { return }
        previousKeyWindow = window
        previousResponder = nil
        previousSelection = nil
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            previousResponder = field
            previousSelection = editor.selectedRange()
        } else {
            previousResponder = window.firstResponder as? NSView
        }
    }

    /// Gives the keys back to the window that had them if it is still on screen here: the island's panel by taking the
    /// keyboard again as its field does when clicked, any other window by becoming key. The view that had them gets
    /// them back if the window took them from it, a field with its caret where it stood.
    private func returnKeys() {
        guard let window = previousKeyWindow, window !== panel, window.isVisible, window.isOnActiveSpace else { return }
        if let overlay = window as? OverlayPanel {
            // A HUD panel takes the keyboard only for the field typed in before; one that has gone with its card while
            // the menu was open would leave the panel holding keys the app in front should have.
            guard let view = previousResponder, view.window === overlay else { return }
            overlay.takeKeyboard()
        } else {
            window.makeKey()
        }
        guard let view = previousResponder, view.window === window, window.firstResponder !== view,
              (view as? NSControl)?.currentEditor() == nil, window.makeFirstResponder(view) else { return }
        if let selection = previousSelection, let editor = (view as? NSControl)?.currentEditor() {
            let length = (editor.string as NSString).length
            editor.selectedRange = NSRange(location: min(selection.location, length),
                                           length: min(selection.length, length - min(selection.location, length)))
        }
    }

    /// The open menu takes the look of its screen again, after a change of the setting, of the screen's look, of the
    /// Mac's light or dark setting, or of Reduce Transparency.
    func refreshLook() {
        guard isMenuOpen, let panel else { return }
        panel.apply(look: Self.menuLook(on: panel.screen ?? item.button?.window?.screen))
    }

    /// The look of the menu on `screen`: with Match screen on, the look a window there takes (`WindowLook`), the HUD's
    /// appearance, material, glass and transparency; otherwise the app's Appearance in regular Liquid Glass at the
    /// standard transparency, drawn as a screen's is at three fifths of it (`ScreenPlacement.drawsTransparency`), which
    /// reads as a macOS menu does, and solid under Reduce Transparency.
    static func menuLook(on screen: NSScreen?) -> HUDLook {
        if let look = WindowLook.look(on: screen) { return look }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let reduces = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        guard !reduces else { return HUDLook(appearance: dark ? .dark : .light) }
        let placement = ScreenPlacement(material: .glass, glassStyle: .regular)
        return HUDLook(appearance: dark ? .dark : .light, material: .glass,
                       transparency: placement.drawsTransparency(reducesTransparency: reduces),
                       glassStyle: placement.glassStyle)
    }

    private func makePanel(look: HUDLook) -> StatusMenuPanel {
        let panel = StatusMenuPanel(look: look)
        panel.onChoose = { [weak self] entry in
            // A menu closes before its item acts, so a window the action opens comes up over no menu.
            self?.closeMenu()
            entry.perform?()
        }
        panel.onDismiss = { [weak self] returningKeys in self?.closeMenu(returningKeys: returningKeys) }
        self.panel = panel
        return panel
    }

    private func startWatchingForDismissal() {
        stopWatchingForDismissal()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // A click in another app gives that app the keys, so the menu leaves them there.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closeMenu(returningKeys: false) }
        }) {
            monitors.append(global)
        }
        // A click in another of the app's windows, the island's included, closes it too; one on the status item is
        // left to the button, which closes it. Only the window's number crosses into the main actor, not the event.
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            let clicked = event.windowNumber
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, clicked != panel.windowNumber,
                      clicked != self.item.button?.window?.windowNumber else { return }
                self.closeMenu()
            }
            return event
        }) {
            monitors.append(local)
        }
        let close: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.closeMenu() }
        }
        // The app resigning gives another app the keys.
        let resign: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.closeMenu(returningKeys: false) }
        }
        // A change of Space closes the menu only when it leaves the menu behind; the Space it opened on coming to the
        // front, or a full-screen app's Space it came along to, does not.
        let leaveSpace: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !panel.isOnActiveSpace else { return }
                self.closeMenu()
            }
        }
        observers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                   queue: .main, using: resign),
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main, using: close),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                              object: nil, queue: .main, using: leaveSpace),
        ]
    }

    private func stopWatchingForDismissal() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    // MARK: Entries

    /// The menu's lines on `screen`, top to bottom: each vendor's quota rows under its name when there are several, each
    /// account's under its header, then the balances, then the actions, the host's own between Settings and Quit. The
    /// vendors and the balances are those the screen's HUD shows at rest, in the order its layout lists them
    /// (`agents(on:)`), a balance by its vendor as the Simple panel's items take it, and a balance's tooltip says its
    /// estimated cost over the period its card in that screen's panel covers (`PanelLayout.costPeriod(of:)`). For no
    /// display, every vendor and balance, and the shared layout's periods.
    func menuEntries(on screen: Screen? = nil) -> [StatusMenuEntry] {
        var entries: [StatusMenuEntry] = []
        let shown = agents(on: screen).order
        let layout = settings.panelLayout.effective(for: screen?.key)
        let groups = shown.arrange(store.rowGroups) { $0.vendor }
        let balances = shown.arrange(store.enabledBilling, vendor: \.vendor)
        for (index, group) in groups.enumerated() {
            if index > 0 { entries.append(.separator) }
            if groups.count > 1 || group.rows.count > 1 {
                entries.append(StatusMenuEntry(title: group.vendor, icon: .artwork(vendor: group.vendor), weight: .agent,
                                               isEnabled: false))
            }
            for section in store.accountSections(group.rows) {
                if let account = section.account {
                    entries.append(StatusMenuEntry(
                        title: [account.displayName, account.planLabel].compactMap { $0 }.joined(separator: " · "),
                        value: store.accountLabel(for: account), weight: .small, titleInk: .secondary,
                        toolTip: store.accountNotice(for: section), isEnabled: false))
                }
                for row in section.rows {
                    entries.append(rowEntry(row, showVendor: groups.count == 1 && group.rows.count == 1 && section.account == nil))
                }
            }
        }
        for (index, billing) in balances.enumerated() {
            if !groups.isEmpty || index > 0 { entries.append(.separator) }
            let balance = billing.balances.map { MoneyFormat.amount($0.total, currency: $0.currency) }.joined(separator: " / ")
            let title = (billing.billingPool == nil ? billing.vendor : billing.displayName) + L10n.text(" · 余额", " · Balance")
            // Over the span the panel's token chart draws for the period, as the card in the panel says it; the
            // statistics window's range never changes it.
            let period = layout.costPeriod(of: billing)
            let cost = billing.estimatedCost(currency: billing.currency, during: store.hudTokenInterval(period))
                .map { MoneyFormat.amount($0, currency: billing.currency, estimated: true) } ?? "—"
            entries.append(StatusMenuEntry(
                title: title, value: balance.isEmpty ? "—" : balance, icon: .artwork(vendor: billing.vendor),
                weight: .agent, valueInk: Self.valueInk(store.view.level(of: billing)),
                // A balance whose read failed says why before its cost.
                toolTip: [store.view.assessment(of: billing).status.reason,
                          L10n.text("费用估算 · ", "Est. cost · ") + period.range.recentLabel + ": " + cost]
                    .compactMap { $0 }.joined(separator: "\n"),
                perform: { [weak self] in self?.actions.openStats() }))
        }
        if store.rows.isEmpty && store.enabledBilling.isEmpty {
            entries.append(StatusMenuEntry(title: L10n.text("没有启用的模型", "No agents enabled"), titleInk: .secondary,
                                           isEnabled: false))
        }
        entries.append(.separator)
        entries.append(action(
            store.glowHidden ? L10n.text("显示灵动岛光晕", "Show notch glow") : L10n.text("隐藏灵动岛光晕", "Hide notch glow"),
            key: "h", modifiers: [.command, .option]) { [weak self] in self?.actions.toggleGlow() })
        entries.append(.separator)
        entries.append(action(L10n.text("设置…", "Settings…"), key: ",", modifiers: [.command]) { [weak self] in
            self?.actions.openSettings()
        })
        entries += additionalMenuItems().compactMap(Self.hostEntry)
        entries.append(action(L10n.text("退出", "Quit"), key: "q", modifiers: [.command]) { [weak self] in
            self?.actions.quit()
        })
        return entries
    }

    private func rowEntry(_ row: AgentRow, showVendor: Bool) -> StatusMenuEntry {
        let value: String
        if let used = row.usedPct {
            value = "\(TokenFormat.percent(used)) · \(row.resetLabel(now: store.now, compact: true))"
        } else {
            value = row.missingQuotaLabel
        }
        return StatusMenuEntry(
            title: showVendor ? row.agent.compactName : row.agent.name, value: value,
            icon: showVendor ? .artwork(vendor: row.agent.vendor) : .dot(row.level),
            weight: showVendor ? .agent : .regular,
            titleInk: row.isCurrentAccount ? .primary : .secondary, valueInk: Self.valueInk(row.level),
            toolTip: store.quotaForecastHint(for: row.id),
            perform: { [weak self] in self?.actions.openStats() })
    }

    /// The ink of a quota row's or a balance's figure: the look's critical text colour at a critical level, else its
    /// secondary ink.
    static func valueInk(_ level: StatusLevel?) -> StatusMenuEntry.Ink {
        level == .critical ? .critical : .secondary
    }

    private func action(_ title: String, key: String, modifiers: NSEvent.ModifierFlags,
                        perform: @escaping @MainActor () -> Void) -> StatusMenuEntry {
        StatusMenuEntry(title: title, value: StatusMenuEntry.shortcut(key: key, modifiers: modifiers),
                        keyEquivalent: key, modifiers: modifiers, perform: perform)
    }

    /// A host's item as a line of the menu, drawn from its title, the colour of its attributed title, its image, its
    /// state and whether it is enabled, and chosen by sending its action to its target, from the item, as a menu
    /// would. A host's separator is a separator, and a hidden item is left out. A custom view or a submenu is not drawn.
    static func hostEntry(_ item: NSMenuItem) -> StatusMenuEntry? {
        if item.isSeparatorItem { return .separator }
        guard !item.isHidden else { return nil }
        var tint: NSColor?
        if let attributed = item.attributedTitle, attributed.length > 0 {
            tint = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        var icon = StatusMenuEntry.Icon.none
        if item.state != .off {
            icon = .state(item.state)
        } else if let image = item.image {
            icon = .image(image)
        }
        var titleInk = StatusMenuEntry.Ink.primary
        if !item.isEnabled {
            titleInk = .tertiary
        } else if let tint {
            titleInk = .custom(tint)
        }
        var perform: (@MainActor () -> Void)?
        if let action = item.action {
            perform = { NSApp.sendAction(action, to: item.target, from: item) }
        }
        return StatusMenuEntry(
            title: item.title, value: StatusMenuEntry.shortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask),
            icon: icon, titleInk: titleInk,
            valueInk: item.isEnabled ? .secondary : .tertiary,
            toolTip: item.toolTip, isEnabled: item.isEnabled, keyEquivalent: item.keyEquivalent,
            modifiers: item.keyEquivalentModifierMask, perform: perform)
    }
}
