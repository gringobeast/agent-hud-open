import Foundation

/// What a session's own log says its turn is busy with: the calls still waiting for their result, the kind of work its
/// newest calls do, and what its newest line is. Only the clients whose logs record each tool call have one (Claude Code,
/// Codex, Grok CLI, DeepSeek Harness). It says nothing about whether the turn is in flight, which `SessionTurn` and the
/// session's phase do, and holds only times its log wrote, never one it was read at.
public struct SessionActivity: Hashable, Codable, Sendable {
    /// What a call does, by the groups a permission request names its tool with (`PermissionRequest.group(ofTool:)`).
    public enum Work: String, Hashable, Codable, Sendable {
        /// A shell command: Claude Code's Bash, Codex's exec. The only work that can show as a long command.
        case shell
        /// Any other command: an MCP tool, Codex's js.
        case command
        case edit
        /// Reading, searching or fetching.
        case read
        /// Starting, messaging or waiting on sub-agents: Claude Code's Task and Agent, Codex's collaboration tools.
        case agents
        /// Asking the user something: Codex's request_user_input_async.
        case question

        /// Whether a session shows this work as what it is doing: a command, an edit or a read. Sub-agents and questions
        /// show as themselves, beside or instead of it.
        public var isShown: Bool { self != .agents && self != .question }
    }

    /// A call still waiting for its result.
    public struct Call: Hashable, Codable, Sendable {
        public let id: String
        /// Nil for a tool no group names, such as a to-do list or a tool search: such a call never changes what the
        /// session shows, though it still waits for its result.
        public let work: Work?
        public let at: Date

        public init(id: String, work: Work?, at: Date) {
            self.id = id; self.work = work; self.at = at
        }
    }

    /// A question the client puts to its user in its own window, with no hook to report it: the Claude desktop app's
    /// next-step box and its card offering a task a session of its own. Only the call that asks it says what it asks.
    public struct Ask: Hashable, Codable, Sendable {
        public enum Kind: String, Hashable, Codable, Sendable {
            /// The box a turn ends with: a recap, one question and one or two answers, each of which the app sends as the
            /// user's next message. It stands until the next prompt.
            case nextStep
            /// A task the agent offers to start in a new session, while its turn waits for the user to choose a new
            /// session or this one. It stands until the call's result.
            case offer
        }

        /// One of the answers the client's window offers, with the words it sends for the user when one is given.
        public struct Option: Hashable, Codable, Sendable {
            public let label: String
            public let message: String?

            public init(label: String, message: String? = nil) {
                self.label = label; self.message = message
            }
        }

        /// The call that asks it, and the response that made the call: the other calls of that response leave it standing.
        public let id: String
        public let response: String?
        public let kind: Kind
        /// The question, or the offered task's title. Its words, the recap and the options are kept only while the app
        /// runs, as a turn's message is: the ledger that keeps a log's summary stores no conversation text, so an ask read
        /// back from it is empty and still says that the session waits.
        public let question: String
        /// What the agent says has been done, which the next-step box shows above the question.
        public let recap: String?
        public let options: [Option]
        public let at: Date
        /// Where the call's line begins in its log: the ledger keeps this, not the words, so a later run reads them again
        /// from that one line.
        public var offset: Int?
        enum CodingKeys: String, CodingKey { case id, response, kind, at, offset }

        /// Whether its words were read in this run.
        public var isWorded: Bool { !question.isEmpty }

        public init(id: String, response: String? = nil, kind: Kind, question: String, recap: String? = nil, options: [Option],
                    at: Date, offset: Int? = nil) {
            self.id = id; self.response = response; self.kind = kind; self.question = question; self.recap = recap
            self.options = options; self.at = at; self.offset = offset
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try c.decode(String.self, forKey: .id), response: try c.decodeIfPresent(String.self, forKey: .response),
                      kind: try c.decode(Kind.self, forKey: .kind), question: "", options: [], at: try c.decode(Date.self, forKey: .at),
                      offset: try c.decodeIfPresent(Int.self, forKey: .offset))
        }
    }

    /// What the newest line of the conversation holds.
    public enum Line: String, Hashable, Codable, Sendable {
        /// The prompt that started the turn.
        case prompt
        /// Anything else the user's side added: context a hook or a skill injected, a compaction's summary.
        case context
        case call
        case result
        /// A thinking block, which the client writes once it is finished.
        case thinking
        /// Text the agent wrote without ending the turn.
        case text
        /// The answer that ended the turn.
        case answer
        /// The message the client writes in the model's place when the API failed the turn.
        case error
    }

    /// The calls of the turn still waiting for their result, oldest first.
    public private(set) var calls: [Call] = []
    /// The kind of work the turn's calls do as the log was last read, a command, an edit or a read: the newest call still
    /// open, else the newest one that read brought in, else what the read before said. Nil before the turn's first call.
    public private(set) var work: Work?
    /// When the newest call was last seen: when it was made, or when its result came back if that is later.
    public private(set) var toolAt: Date?
    /// The newest line of the conversation; nil for a client whose log does not tell.
    public var line: Line?
    /// Whether the newest line of any kind says the client is trying a failed API request again.
    public var retrying = false
    /// The newest line of the session's sub-agents that are themselves at work; nil when none is.
    public var subagentsAt: Date?
    /// When the client said it began compacting the conversation, while that is newer than the log's last line
    /// (`CompactionHooks`).
    public var compactingSince: Date?
    /// The question the client asks its user in its own window, until the user answers it there; nil when none is open.
    public private(set) var ask: Ask?
    /// What the agent has said since the turn's last input, its prompt or a tool's result, while those words are still
    /// the conversation's newest or the question that follows them: the answer it wrote before asking, which the card
    /// that asks shows above the question. Nil once a call to any other tool, the turn's end or the next input follows
    /// them. Kept only while the app runs, as an ask's words are: never encoded.
    public var reply: String?
    /// The newest work the read under way brought in, which `settle()` takes into `work`.
    private var latest: Work?
    enum CodingKeys: String, CodingKey { case calls, work, toolAt, line, retrying, subagentsAt, compactingSince, ask, latest }

    public init() {}

    /// The newest call still open whose work the session shows.
    public var openCall: Call? { calls.last { $0.work?.isShown == true } }

    /// Whether any call of the turn still waits for its result, one no group names included.
    public var hasOpenCall: Bool { !calls.isEmpty }

    /// Whether the session's sub-agents are at work: a call that starts or waits on them is open, or their own logs move.
    public var delegating: Bool { subagentsAt != nil || calls.contains { $0.work == .agents } }

    /// When the open call asking the user something was made; nil when none is open.
    public var askedAt: Date? { calls.last { $0.work == .question }?.at }

    /// Whether the conversation's newest line leaves the model to go on: a prompt, context, a call's result, a thinking
    /// block or text that did not end the turn. A client whose log does not say leaves it open too.
    public var awaitsModel: Bool {
        switch line {
        case nil, .prompt, .context, .result, .thinking, .text: true
        case .call, .answer, .error: false
        }
    }

    // MARK: Reading

    /// A new turn starts: nothing of the last one is open, and nothing it did says what this one does. Whatever the last
    /// one asked has its answer: the prompt is it, or the user moved on.
    public mutating func startTurn() {
        calls = []
        work = nil
        toolAt = nil
        latest = nil
        ask = nil
    }

    /// The turn is over: none of its calls waits for a result any more.
    public mutating func endTurn() {
        calls = []
        latest = nil
    }

    /// A call made at `at` by `response`, which asks the user `ask` in the client's own window when it is one that does.
    /// A call of a later response takes back what an earlier one asked: the agent went on without the answer. The calls
    /// one response makes together, such as a task list's last tick beside the next-step box, leave its question standing.
    public mutating func open(_ id: String, work: Work?, at: Date, response: String? = nil, asking ask: Ask? = nil) {
        calls.removeAll { $0.id == id }
        calls.append(Call(id: id, work: work, at: at))
        if let work, work.isShown { latest = work }
        toolAt = max(toolAt ?? at, at)
        if let ask {
            self.ask = ask
        } else if let asked = self.ask, asked.response == nil || asked.response != response {
            self.ask = nil
        }
    }

    /// The words of the question still asked, read again from its call's line after the ledger gave it back without
    /// them. Only the same call's words are taken, and only while none are there.
    public mutating func reword(_ read: Ask) {
        guard let asked = ask, asked.id == read.id, !asked.isWorded, read.isWorded else { return }
        var worded = read
        worded.offset = asked.offset ?? read.offset
        ask = worded
    }

    /// A call's result came back at `at`, `failed` when the client marked it an error. An offer is answered by its result;
    /// a next-step box is shown by its own and stays until the next prompt, unless the result is the app refusing it.
    public mutating func close(_ id: String, at: Date, failed: Bool = false) {
        calls.removeAll { $0.id == id }
        toolAt = max(toolAt ?? at, at)
        if ask?.id == id, ask?.kind == .offer || failed { ask = nil }
    }

    /// Work the log records only once it is done, such as a file Codex changed, as if a call of it had been made and
    /// answered at `at`.
    public mutating func did(_ work: Work, at: Date) {
        if work.isShown { latest = work }
        toolAt = max(toolAt ?? at, at)
    }

    /// Ends one read of the log: the newest open call says what the turn does, else the newest work the read brought in,
    /// else the turn keeps what the read before said.
    public mutating func settle() {
        if let open = openCall?.work { work = open } else if let latest { work = latest }
        latest = nil
    }

    // MARK: Tools

    /// What a call of `tool` does, by the group a permission request shows it with; nil for a tool no group names, and
    /// for the questions and plans the user answers, which are requests rather than work.
    public static func work(ofTool tool: String) -> Work? {
        switch PermissionRequest.group(ofTool: tool) {
        case "BASH": .shell
        case "MCP": .command
        case "EDIT": .edit
        case "READ", "FIND", "WEB": .read
        case "AGENT": .agents
        default: nil
        }
    }
}
