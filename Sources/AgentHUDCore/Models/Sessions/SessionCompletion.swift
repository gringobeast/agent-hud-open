import AgentHUDSupport
import Foundation

/// An explicit, successful end of one turn. Inactivity is never a completion.
public struct SessionCompletion: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let vendor: String
    /// Execution client, distinct from the account provider.
    public var client: String?
    public var agentVendor: String { SessionSource(vendor: vendor, client: client).agentVendor ?? vendor }
    public var task: String
    public let model: String
    public let startedAt: Date?
    public let completedAt: Date
    /// The final reply's last paragraph, kept only in memory for the local completion reminder.
    public let message: String?
    /// The whole final reply, everything the agent said after the turn's last input, clipped to `replyLength`
    /// characters: what the expanded reminder shows. Kept only in memory, like `message`; never encoded.
    public var reply: String?
    /// Every token the turn's API calls spent, from its prompt to this answer, by kind: what the source counted, nil where
    /// it did not. Kept only in memory, like `reply`; never encoded.
    public var tokens: TokenKinds?
    /// What those calls would cost at the vendors' API list prices (`ModelCatalog`); nil when a model they called has no
    /// list price. Kept only in memory.
    public var listCost: ModelCatalog.Cost?
    /// Source-owned destination on this Mac; never encoded with completion reports.
    public var navigationTarget: SessionNavigationTarget?

    public init(sessionID: String, vendor: String, turnID: String, task: String, model: String,
                startedAt: Date?, completedAt: Date, message: String? = nil, navigationTarget: SessionNavigationTarget? = nil,
                client: String? = nil, reply: String? = nil, tokens: TokenKinds? = nil, listCost: ModelCatalog.Cost? = nil) {
        id = RecordCoding.hash([vendor, sessionID, turnID])
        self.sessionID = sessionID; self.vendor = vendor; self.task = task; self.model = model
        self.client = client
        self.startedAt = startedAt; self.completedAt = completedAt
        self.message = Self.lastParagraph(message)
        self.reply = Self.clipped(reply)
        self.tokens = tokens
        self.listCost = listCost
        self.navigationTarget = navigationTarget
    }

    /// How long the turn took, from its prompt to this answer; nil when its start is unknown.
    public var duration: TimeInterval? { startedAt.map { max(0, completedAt.timeIntervalSince($0)) } }

    /// The turn in one line, each part only where it is known: "4m 12s · 1.2M tok · $3.84 API"; nil when none is.
    public var turnSummary: String? {
        var parts: [String] = []
        if let duration { parts.append(Self.durationText(duration)) }
        if let tokens {
            let count = TokenFormat.short(tokens.total)
            parts.append(L10n.text("\(count) Token", "\(count) tok"))
        }
        if let listCost {
            let amount = MoneyFormat.short(listCost.amount, currency: listCost.currency)
            parts.append(L10n.text("API 价 \(amount)", "\(amount) API"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A turn's length to the second while it is under an hour: "42s", "4m 12s", then "1h 05m".
    static func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" }
        return Countdown.format(interval)
    }

    /// The longest reply a reminder keeps, in characters.
    public static let replyLength = 8000

    /// `reply` trimmed, cut to `replyLength` characters with an ellipsis; nil when nothing is left.
    static func clipped(_ reply: String?) -> String? {
        guard let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > replyLength ? String(text.prefix(replyLength - 1)) + "…" : text
    }

    static func lastParagraph(_ message: String?) -> String? {
        guard let message else { return nil }
        var lines: [Substring] = []
        for line in message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).reversed() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !lines.isEmpty { break }
            } else {
                lines.append(line)
            }
        }
        let paragraph = lines.reversed().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paragraph.isEmpty else { return nil }
        return paragraph.count > 600 ? String(paragraph.prefix(599)) + "…" : paragraph
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, vendor, client, task, model, startedAt, completedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        vendor = try values.decode(String.self, forKey: .vendor)
        client = try values.decodeIfPresent(String.self, forKey: .client)
        task = try values.decode(String.self, forKey: .task)
        model = try values.decode(String.self, forKey: .model)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try values.decode(Date.self, forKey: .completedAt)
        message = nil
        reply = nil
        tokens = nil
        listCost = nil
        navigationTarget = nil
    }
}
