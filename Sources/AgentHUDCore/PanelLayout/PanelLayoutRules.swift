import Foundation

/// What a block of the hover panel holds: one agent's quota windows, readings with a ceiling, or one API account's
/// balance, money without one.
public enum PanelBlockKind: String, Sendable { case quota, billing }

public extension PanelBlockKind {
    /// The widgets the kind accepts, its default first. A bar and a ring draw a share of a ceiling, and a balance has
    /// none, so a balance is a number, its card, or a chart of what its requests cost over time.
    var widgets: [PanelWidget] {
        switch self {
        case .quota: [.bar, .ring, .number, .chart]
        case .billing: [.number, .chart]
        }
    }

    /// The measures the kind offers under a widget, in picker order; none under a widget it does not accept. A chart of
    /// quota windows draws the history the panel holds, tokens. A balance is money: its number offers the balance beside
    /// its estimated cost (`quota`), the pace its recorded costs set and when the balance runs out at it (`burn`), and
    /// the estimated cost beside that pace (`cost`); it also reads the tokens of its own consumers like a quota window
    /// (`tokens`, `consumed`); its chart draws the estimated cost over time.
    func measures(under widget: PanelWidget) -> [PanelMeasure] {
        switch (self, widget) {
        case (.quota, .bar), (.quota, .ring), (.quota, .number): [.quota, .burnRate, .tokens, .consumed, .cost]
        case (.quota, .chart): [.tokens]
        case (.billing, .number): [.quota, .burnRate, .tokens, .consumed, .cost]
        case (.billing, .chart): [.cost]
        case (.billing, _): []
        }
    }
}

extension PanelBlockKind {
    /// The widget of the default view: bars for quota windows, a number for a balance.
    var defaultWidget: PanelWidget {
        switch self {
        case .quota: .bar
        case .billing: .number
        }
    }

    /// The widget that draws a block a layout asks to draw with `asked`: that one where the kind accepts it, else the
    /// kind's default.
    func widget(for asked: PanelWidget?) -> PanelWidget {
        guard let asked, widgets.contains(asked) else { return defaultWidget }
        return asked
    }

    /// The measures a block's picker offers under `widget` when a layout lists `asked`: those of them the widget
    /// offers, each once, in the order listed; every measure the widget offers when that leaves none.
    func measures(_ asked: [PanelMeasure], under widget: PanelWidget) -> [PanelMeasure] {
        let offered = measures(under: widget)
        let kept = asked.withoutRepeats.filter(offered.contains)
        return kept.isEmpty ? offered : kept
    }

    /// Whether a layout can hide the kind's reset times: a quota window resets, a balance does not.
    var takesCountdown: Bool { self == .quota }

    /// Whether the kind's blocks drawn with `widget` stand in cells a layout sets in columns: quota windows as rings
    /// or numbers. A balance's number is its card.
    func takesColumns(under widget: PanelWidget) -> Bool { self == .quota && widget.drawsCells }

    /// Whether the kind's blocks drawn with `widget` have rings a layout sizes: quota windows as rings.
    func takesRingSize(under widget: PanelWidget) -> Bool { self == .quota && widget == .ring }

    /// Whether the kind's blocks drawn with `widget` can take half a line: cells, a chart and a balance's card can. Bar
    /// rows cannot: their columns take about 366 pt, which half of the widest panel does not leave.
    func takesHalf(under widget: PanelWidget) -> Bool { widget != .bar }

    /// Whether the kind's blocks drawn with `widget` cover a period a layout sets: quota windows as a chart, whose bars
    /// are their models' tokens over it, and a balance under either widget, whose estimated cost, the pace it sets and
    /// its chart's bars cover it.
    func takesPeriod(under widget: PanelWidget) -> Bool { (self == .quota && widget == .chart) || self == .billing }

    /// The period a block covers where its layout gives none: the latest 24 hours on a quota block's chart, as before
    /// blocks had a period, and on a balance, drawn as its card or as a chart, the period the layout's token chart
    /// starts from, `tokens`.
    func defaultPeriod(tokens: PanelTokenPeriod) -> PanelTokenPeriod { self == .billing ? tokens : .day }
}

/// One block the hover panel has now. A list of them is in the panel's default order.
public struct PanelBlockInfo: Hashable, Sendable {
    /// One account of a block: a section of a quota block's rows, or one API account's balance.
    public struct Account: Hashable, Sendable {
        /// The id a layout names the account by: a quota account's `ProviderAccount.id`, an API account's `APIBilling.id`,
        /// the ids Settings → Agents keeps an account's switch under. Empty for rows that belong to no account, which no
        /// layout names.
        public let id: String
        /// The account's email or name as the panel writes it; nil for rows that belong to no account.
        public let name: String?
        /// The keys of the account's rows, in row order. A balance has none.
        public let rowKeys: [String]

        public init(id: String, name: String? = nil, rowKeys: [String] = []) {
            self.id = id
            self.name = name
            self.rowKeys = rowKeys
        }
    }

    /// A quota block's vendor id (`AgentDescriptor.displayVendor`), an API account's `APIBilling.panelBlockKey`.
    public let key: String
    public let kind: PanelBlockKind
    /// The block's rows in default order: each quota window's `AgentDescriptor.windowKey`, once however many accounts
    /// have that window. A balance has no rows.
    public let rowKeys: [String]
    /// The block's accounts in the order the panel draws them: a quota block's sections, rows of no account among them
    /// under an empty id, and a balance block's accounts.
    public let accounts: [Account]

    public init(key: String, kind: PanelBlockKind, rowKeys: [String] = [], accounts: [Account] = []) {
        self.key = key
        self.kind = kind
        self.rowKeys = rowKeys
        self.accounts = accounts
    }

    /// The accounts a layout can name, without the rows of no account.
    var namedAccounts: [Account] { accounts.filter { !$0.id.isEmpty } }
}

public extension APIBilling {
    /// The key of the block that shows this account's balance: `api:` and the provider that bills it, which no vendor
    /// id is. Accounts of one provider share a block.
    var panelBlockKey: String { "api:" + (billingPool?.provider ?? vendor) }
}

public extension PanelLayout {
    /// The period an API account's estimated cost covers under the layout, on its card in the hover panel and in the
    /// menu-bar menu's tooltip alike: its block's `period`, else the period the token chart starts from, else the latest
    /// 24 hours (`PanelBlockKind.defaultPeriod(tokens:)`).
    func costPeriod(of billing: APIBilling) -> PanelTokenPeriod {
        blocks[billing.panelBlockKey]?.period ?? PanelBlockKind.billing.defaultPeriod(tokens: tokens.chartPeriod)
    }
}

public extension ReportView {
    /// The blocks the panel has, in default order: a quota block for each vendor's rows in row order, with its accounts'
    /// sections, then an empty quota block for each vendor that has only a notice (`accountlessNotices`), then a billing
    /// block for each API provider whose balance is shown, in the order of the balances, with its accounts.
    var panelBlocks: [PanelBlockInfo] {
        var blocks = rowGroups.map { group in
            let accounts = accountSections(group.rows).map { section in
                PanelBlockInfo.Account(id: section.id, name: section.account?.displayName,
                                       rowKeys: section.rows.map(\.agent.windowKey).withoutRepeats)
            }
            return PanelBlockInfo(key: group.vendor, kind: .quota, rowKeys: group.rows.map(\.agent.windowKey).withoutRepeats,
                                  accounts: accounts)
        }
        blocks += accountlessNotices.map { PanelBlockInfo(key: $0.vendor, kind: .quota) }
        var keys = Set(blocks.map(\.key))
        for account in billing where keys.insert(account.panelBlockKey).inserted {
            let accounts = billing.filter { $0.panelBlockKey == account.panelBlockKey }.map {
                PanelBlockInfo.Account(id: $0.id, name: $0.displayName)
            }
            blocks.append(PanelBlockInfo(key: account.panelBlockKey, kind: .billing, accounts: accounts))
        }
        return blocks
    }
}

/// One thing a proposed layout asks for that the panel cannot do as asked, worded for the agent that proposed it.
struct PanelLayoutIssue: Hashable, Sendable {
    /// Where in the layout's JSON: its keys from the root joined by dots, a list's element by its index in brackets,
    /// such as `blocks.Claude.widget` or `order[2]`.
    let path: String
    /// An English sentence an agent can relay: what is wrong, and what the panel has or accepts instead.
    let message: String
}

extension PanelLayout {
    /// Every issue of the layout against the blocks the panel has now, blocks by key and then `order` by position: a
    /// block key or an order entry that names no block, a widget its block's kind does not accept, a measure that is
    /// not offered under the widget the block is drawn with, a countdown on a balance, columns or a ring size where the
    /// block has no cells or no rings, half a line for bar rows, a period where the block draws no chart and is no
    /// balance, a hidden row or a row of its order its block does not have, and an account it does not have. A layout
    /// with issues still resolves (`PanelLayoutPlan`): what cannot be done as asked falls back or waits.
    ///
    /// What one of the `held` layouts already holds for a block, a row or an account that is away is no issue when it
    /// comes back as it is held: the block's own entry unchanged, its key in `order`, the row among its block's hidden
    /// rows or in its order, the account among its accounts. A layout keeps those until the block, the row or the
    /// account returns, so a proposal built on a layout that was read may carry them.
    func issues(against existing: [PanelBlockInfo], holding held: [PanelLayout] = []) -> [PanelLayoutIssue] {
        var known: [String: PanelBlockInfo] = [:]
        for block in existing where known[block.key] == nil { known[block.key] = block }
        let unknownKey = existing.isEmpty ? "The panel has no blocks now."
            : "The panel's blocks now: \(Self.quoted(existing.map(\.key).withoutRepeats))."
        var issues: [PanelLayoutIssue] = []
        for key in blocks.keys.sorted() {
            let change = blocks[key] ?? Block()
            let heldAs: [Block] = held.compactMap { $0.blocks[key]?.normalized() }
            if let block = known[key] {
                var heldRows = Set<String>(), heldAccounts = Set<String>()
                for kept in heldAs {
                    heldRows.formUnion(kept.hiddenRows + kept.rows)
                    heldAccounts.formUnion(kept.accounts)
                }
                issues += Self.issues(of: change, in: block, holding: heldRows, accounts: heldAccounts)
            } else if heldAs.isEmpty {
                issues.append(PanelLayoutIssue(path: "blocks.\(key)", message: "No block has the key \"\(key)\". \(unknownKey)"))
            } else if !heldAs.contains(change.normalized()) {
                let message = "No block has the key \"\(key)\" now. The layout holds it for a block that is away: "
                    + "send it back as it is, or leave it out. \(unknownKey)"
                issues.append(PanelLayoutIssue(path: "blocks.\(key)", message: message))
            }
        }
        var heldKeys = Set<String>()
        for layout in held {
            heldKeys.formUnion(layout.blocks.keys)
            heldKeys.formUnion(layout.order)
        }
        for (index, key) in order.enumerated() where known[key] == nil && !heldKeys.contains(key) {
            issues.append(PanelLayoutIssue(path: "order[\(index)]", message: "No block has the key \"\(key)\". \(unknownKey)"))
        }
        return issues
    }

    private static func issues(of change: Block, in block: PanelBlockInfo, holding heldRows: Set<String>,
                               accounts heldAccounts: Set<String>) -> [PanelLayoutIssue] {
        let kind = block.kind, path = "blocks.\(block.key)"
        var issues: [PanelLayoutIssue] = []
        if let widget = change.widget, !kind.widgets.contains(widget) {
            let accepted = "It accepts: \(quoted(kind.widgets.map(\.rawValue)))."
            issues.append(PanelLayoutIssue(path: path + ".widget", message: "\(refusal(of: widget, by: block)) \(accepted)"))
        }
        let widget = kind.widget(for: change.widget)
        let offered = kind.measures(under: widget)
        let drawn = "The \"\(widget.rawValue)\" widget of \"\(block.key)\""
        let balance = "\"\(block.key)\" is an API balance"
        for (index, measure) in change.measures.enumerated() where !offered.contains(measure) {
            let why = reason(for: measure, kind: kind, under: widget)
            let message = "\(drawn) does not offer the measure \"\(measure.rawValue)\".\(why)"
            issues.append(PanelLayoutIssue(path: path + ".measures[\(index)]",
                                           message: "\(message) It offers: \(quoted(offered.map(\.rawValue)))."))
        }
        if change.countdown != nil && !kind.takesCountdown {
            issues.append(PanelLayoutIssue(path: path + ".countdown",
                                           message: "\(balance), which has no reset to count down to. countdown applies to quota blocks."))
        }
        if change.columns != nil && !kind.takesColumns(under: widget) {
            let drawnAs = widget == .chart ? "a chart of its estimated cost" : "its card"
            let message: String = kind == .billing ? "\(balance), drawn as \(drawnAs), which has no cells to set in columns."
                : "\(drawn) draws no cells. columns applies to the \"ring\" and \"number\" widgets."
            issues.append(PanelLayoutIssue(path: path + ".columns", message: message))
        }
        if change.ringSize != nil && !kind.takesRingSize(under: widget) {
            let message: String = kind == .billing ? "\(balance), which draws no ring."
                : "\(drawn) draws no ring. ringSize applies to the \"ring\" widget."
            issues.append(PanelLayoutIssue(path: path + ".ringSize", message: message))
        }
        if change.span == .half && !kind.takesHalf(under: widget) {
            let message = "Bar rows need the full width of the panel, so the \"\(widget.rawValue)\" widget of \"\(block.key)\" "
                + "cannot take half a line. span \"half\" applies to the \"ring\", \"number\" and \"chart\" widgets and to API "
                + "balances."
            issues.append(PanelLayoutIssue(path: path + ".span", message: message))
        }
        if change.period != nil && !kind.takesPeriod(under: widget) {
            let message = "\(drawn) draws no chart. period applies to the \"chart\" widget, whose bars cover it, and to API "
                + "balances, whose estimated cost, burn rate and chart cover it."
            issues.append(PanelLayoutIssue(path: path + ".period", message: message))
        }
        let rows = block.rowKeys.isEmpty ? "It has no rows to hide." : "Its rows: \(quoted(block.rowKeys))."
        for (index, row) in change.hiddenRows.enumerated() where !block.rowKeys.contains(row) && !heldRows.contains(row) {
            issues.append(PanelLayoutIssue(path: path + ".hiddenRows[\(index)]",
                                           message: "\"\(block.key)\" has no row \"\(row)\". \(rows)"))
        }
        let order = block.rowKeys.isEmpty ? "It has no rows to order." : "Its rows: \(quoted(block.rowKeys))."
        for (index, row) in change.rows.enumerated() where !block.rowKeys.contains(row) && !heldRows.contains(row) {
            issues.append(PanelLayoutIssue(path: path + ".rows[\(index)]",
                                           message: "\"\(block.key)\" has no row \"\(row)\". \(order)"))
        }
        let named = block.namedAccounts
        let accounts = named.isEmpty ? "It has no account to choose now."
            : "Its accounts: " + named.map { "\"\($0.id)\"" + ($0.name.map { " (\($0))" } ?? "") }.joined(separator: ", ") + "."
        let ids = Set(named.map(\.id)).union(heldAccounts)
        for (index, id) in change.accounts.enumerated() where !ids.contains(id) {
            issues.append(PanelLayoutIssue(path: path + ".accounts[\(index)]",
                                           message: "\"\(block.key)\" has no account \"\(id)\". \(accounts)"))
        }
        return issues
    }

    /// Why a block's kind does not accept a widget, in plain words.
    private static func refusal(of widget: PanelWidget, by block: PanelBlockInfo) -> String {
        switch (block.kind, widget) {
        case (.billing, .bar), (.billing, .ring):
            "\"\(block.key)\" is an API balance, which has no ceiling, so the \"\(widget.rawValue)\" widget has nothing to measure it against."
        default:
            "\"\(block.key)\" does not accept the \"\(widget.rawValue)\" widget."
        }
    }

    /// Why a block of `kind` drawn with `widget` does not offer a measure, where more can be said than what it offers
    /// instead: a balance is money, whose models' tokens the token chart draws, and its chart draws its estimated cost
    /// alone. Empty, or a sentence with a space before it.
    private static func reason(for measure: PanelMeasure, kind: PanelBlockKind, under widget: PanelWidget) -> String {
        switch (kind, widget) {
        case (.billing, .chart):
            " The \"chart\" widget of an API balance draws its estimated cost over its period."
        case (.billing, _) where measure == .tokens || measure == .consumed:
            " An API balance draws its models' tokens under the \"number\" widget."
        default:
            ""
        }
    }

    /// Names in quotes, separated by commas.
    static func quoted(_ names: [String]) -> String {
        names.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    // MARK: What a layout changes

    /// The layout reduced to what it changes about the blocks the panel has now, so that two layouts that draw those
    /// blocks alike are the same layout. For a block the panel has, its widget is left out where it is its kind's
    /// default; its measures are kept to those its widget offers and left out where that is none or every one in the
    /// widget's own order; a countdown, columns or a ring size is left out where the block has none to set, and columns
    /// or a ring size where it is the default; a span is left out where it is the whole line or the block cannot take
    /// half of one; a period where the block covers none or it is the one the block covers by default, on a balance the
    /// token chart's (`PanelBlockKind.defaultPeriod(tokens:)`); and a row's key at the end of the block's `rows` where the
    /// row would come there anyway. A block's key is left out at the end of `order` where the block would come there
    /// anyway. What it holds for a block, a row or an account that is away stays as written, and so do a block's accounts
    /// and its own countdown, which are no defaults of the panel as it is now: accounts that name every account a block
    /// has now still leave out one that comes back or joins later, and a countdown that is the layout's now still holds
    /// once the layout's `countdown`, Settings' Reset countdown, is turned the other way. A proposal that spells out the
    /// default view is then the default layout, and one that spells out the saved layout is the saved one.
    func reduced(against existing: [PanelBlockInfo]) -> PanelLayout {
        var known: [String: PanelBlockInfo] = [:]
        for block in existing where known[block.key] == nil { known[block.key] = block }
        var layout = normalized()
        for (key, change) in layout.blocks {
            guard let block = known[key] else { continue }
            let kind = block.kind
            var change = change
            if change.widget == kind.defaultWidget { change.widget = nil }
            let widget = kind.widget(for: change.widget)
            let measures: [PanelMeasure] = kind.measures(change.measures, under: widget)
            change.measures = measures
            if measures == kind.measures(under: widget) { change.measures = [] }
            if !kind.takesCountdown { change.countdown = nil }
            change.rows = Self.reduced(change.rows, among: block.rowKeys)
            if !kind.takesColumns(under: widget) || change.columns == Block.defaultColumns { change.columns = nil }
            if !kind.takesRingSize(under: widget) || change.ringSize == .medium { change.ringSize = nil }
            if change.span == .full || !kind.takesHalf(under: widget) { change.span = nil }
            if !kind.takesPeriod(under: widget) || change.period == kind.defaultPeriod(tokens: layout.tokens.chartPeriod) {
                change.period = nil
            }
            layout.blocks[key] = change
        }
        layout.order = Self.reduced(layout.order, among: existing.map(\.key))
        return layout.normalized()
    }

    /// An order of keys left without the keys at its end that come there anyway: those `present` has, in its order,
    /// that the keys before them would leave in the same place. A key `present` does not have stays, as written.
    private static func reduced(_ order: [String], among present: [String]) -> [String] {
        func shown(_ order: [String]) -> [String] { (order.filter(present.contains) + present).withoutRepeats }
        let asAsked = shown(order)
        var order = order
        while let last = order.last, present.contains(last), shown(Array(order.dropLast())) == asAsked {
            order.removeLast()
        }
        return order
    }
}
