import AgentHUDCore
import AppKit
import SwiftUI

/// What the user has chosen so far on a question card, one entry per question.
///
/// It lives apart from the card: the island redraws its cards as the pointer comes and goes, and neither is a reason
/// to lose an answer half given. It goes when its request leaves the HUD.
@MainActor
@Observable
final class QuestionDraft {
    /// The question on screen.
    var page = 0
    /// The offered answers picked, by question.
    var picks: [Int: Set<Int>] = [:]
    /// The user's own words, by question, and the questions where those words are the answer rather than a draft.
    var own: [Int: String] = [:]
    var ownPicked: Set<Int> = []
    /// Whether the agent's words before the question are open in full rather than their first lines.
    var showsReply = false

    private static var drafts: [String: QuestionDraft] = [:]

    static func draft(for id: String) -> QuestionDraft {
        if let draft = drafts[id] { return draft }
        let draft = QuestionDraft()
        drafts[id] = draft
        return draft
    }

    /// Keeps the drafts of the requests still waiting and forgets the rest.
    static func keep(_ ids: Set<String>) {
        drafts = drafts.filter { ids.contains($0.key) }
    }

    /// Picks an offered answer. A question with one answer takes this one instead of whatever it had; one with
    /// several adds or removes it.
    func pick(_ option: Int, of index: Int, in question: PermissionQuestion) {
        if question.multiSelect {
            picks[index, default: []].formSymmetricDifference([option])
        } else {
            picks[index] = [option]
            ownPicked.remove(index)
        }
    }

    /// Going into the field is choosing to answer in one's own words; with a single answer that sets the offered
    /// ones aside.
    func chooseOwn(of index: Int, in question: PermissionQuestion) {
        ownPicked.insert(index)
        if !question.multiSelect { picks[index] = [] }
    }

    func type(_ text: String, of index: Int, in question: PermissionQuestion) {
        own[index] = text
        chooseOwn(of: index, in: question)
    }

    /// Leaves a question without an answer. What was typed stays, in case the user comes back to it.
    func skip(_ index: Int) {
        picks[index] = []
        ownPicked.remove(index)
    }

    /// The answer as the client files it: an offered label, several in the order they were offered, the user's own
    /// words — or nothing yet.
    func answer(_ index: Int, of question: PermissionQuestion) -> PermissionQuestion.Answer? {
        let selected = question.options.indices.filter { picks[index]?.contains($0) == true }.map { question.options[$0].label }
        var custom: String?
        if ownPicked.contains(index), let text = own[index]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            custom = text
        }
        return selected.isEmpty && custom == nil ? nil : .init(selected: selected, custom: custom)
    }

    /// The answers given, each filed under its question. A question skipped is simply not among them, and the client
    /// reads that as the user leaving it open.
    func answers(for questions: [PermissionQuestion]) -> [String: PermissionQuestion.Answer] {
        var answers: [String: PermissionQuestion.Answer] = [:]
        for (index, question) in questions.enumerated() {
            if let answer = answer(index, of: question) { answers[question.answerKey] = answer }
        }
        return answers
    }
}

/// Whether the user is typing on the island, so it stays open under their hands whatever the pointer does.
struct IslandTypingKey: EnvironmentKey {
    static let defaultValue: @MainActor (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var islandTyping: @MainActor (Bool) -> Void {
        get { self[IslandTypingKey.self] }
        set { self[IslandTypingKey.self] = newValue }
    }
}

/// The words the agent wrote before the question a request asks (`SessionActivity.reply`), looked up as a card is drawn:
/// a log read after the hook fired brings them in the moment its lines are read. Nil without a store, as in a snapshot.
struct QuestionReplyKey: EnvironmentKey {
    static let defaultValue: @MainActor (PermissionRequest) -> String? = { _ in nil }
}

extension EnvironmentValues {
    var questionReply: @MainActor (PermissionRequest) -> String? {
        get { self[QuestionReplyKey.self] }
        set { self[QuestionReplyKey.self] = newValue }
    }
}

/// A question a client put to its user, answered the way the client's own dialog answers it: one of the offered
/// answers, several where the question allows it, or the user's own words. Several questions are answered one after
/// the other and sent together. Any of them can be skipped: the client hears which were left open, which is a gentler
/// thing to be told than a refusal.
struct PermissionQuestionCard: View {
    let request: PermissionRequest
    let onDecide: (PermissionDecision) -> Void
    @Environment(\.islandTyping) private var islandTyping
    @Environment(\.questionReply) private var questionReply
    @Environment(\.permissionColor) private var color

    /// What the agent said in its turn before asking, from the session the request names: only a question its hook
    /// asks, since a client's own window shows its recap instead. Nil for a session the report does not hold.
    @MainActor
    static func reply(for request: PermissionRequest, in store: UsageStore?) -> String? {
        guard request.nativeApproval == nil else { return nil }
        return store?.view.session(request.sessionID)?.session.activity?.reply
    }

    private var draft: QuestionDraft { QuestionDraft.draft(for: request.id) }
    private var questions: [PermissionQuestion] { request.questions }
    private var page: Int { min(max(0, draft.page), questions.count - 1) }
    private var question: PermissionQuestion { questions[page] }
    private var isLast: Bool { page == questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A next-step box's recap: what the agent says is done, above the question it ends on.
            if request.nativeApproval == .clientReply, let recap = request.detail {
                Text(recap).font(.ui(11)).foregroundStyle(color.secondary)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            // What the agent answered just before it asks, so the question can be read without going back to the chat.
            if let reply = questionReply(request) {
                QuestionReplyText(text: reply, expanded: draft.showsReply) { draft.showsReply.toggle() }
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if questions.count > 1 {
                    Text("\(page + 1)/\(questions.count)")
                        .font(.tabular(10, .semibold)).foregroundStyle(color.signalText)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(color.signal.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                }
                Text(question.question)
                    .font(.ui(12, .semibold)).foregroundStyle(color.text)
                    .lineLimit(5).fixedSize(horizontal: false, vertical: true)
            }
            if question.multiSelect {
                Text(L10n.text("可多选", "Choose any")).font(.ui(10)).foregroundStyle(color.tertiary)
            }
            VStack(spacing: 3) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index, option)
                }
                ownRow
            }
            buttons
        }
        .id("\(request.id)-\(page)")
    }

    private func optionRow(_ index: Int, _ option: PermissionQuestion.Option) -> some View {
        let picked = draft.picks[page]?.contains(index) == true
        return Button { draft.pick(index, of: page, in: question) } label: {
            HStack(alignment: .top, spacing: 8) {
                marker(picked).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.ui(11, .medium)).foregroundStyle(color.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let description = option.description {
                        Text(description).font(.ui(10)).foregroundStyle(color.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? color.highlight : color.inset, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("island-question-option-\(index)")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// The user's own words, laid out like the offered answers above it: a name, and the field where a description
    /// would be.
    private var ownRow: some View {
        let picked = draft.ownPicked.contains(page)
        return HStack(alignment: .top, spacing: 8) {
            marker(picked).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(question.options.isEmpty ? L10n.text("回答", "Answer") : L10n.text("其他", "Other"))
                    .font(.ui(11, .medium)).foregroundStyle(color.text)
                IslandTextField(
                    text: draft.own[page] ?? "",
                    placeholder: L10n.text("自己输入回答", "Type your own answer"),
                    onFocus: { draft.chooseOwn(of: page, in: question) },
                    onChange: { draft.type($0, of: page, in: question) },
                    onSubmit: advance,
                    onTyping: islandTyping
                )
                .frame(height: 15)
                .accessibilityIdentifier("island-question-own")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(picked ? color.highlight : color.inset, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { draft.chooseOwn(of: page, in: question) }
    }

    /// A ring for an answer that stands alone, a box for one of several; filled once chosen.
    private func marker(_ picked: Bool) -> some View {
        let symbol = question.multiSelect ? (picked ? "checkmark.square.fill" : "square")
                                          : (picked ? "largecircle.fill.circle" : "circle")
        return Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(picked ? color.text : color.tertiary)
            .frame(width: 12)
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            QuestionButton(title: L10n.text("跳过", "Skip"), symbol: nil, identifier: "island-question-skip",
                           fill: .clear, stroke: color.border, foreground: color.secondary) {
                draft.skip(page)
                next()
            }
            Spacer(minLength: 8)
            if page > 0 {
                QuestionButton(title: L10n.text("返回", "Back"), symbol: "chevron.left", identifier: "island-question-back",
                               fill: .clear, stroke: color.border, foreground: color.secondary) {
                    draft.page = page - 1
                }
            }
            let ready = draft.answer(page, of: question) != nil
            QuestionButton(title: isLast ? L10n.text("提交", "Submit") : L10n.text("继续", "Next"),
                           symbol: isLast ? "checkmark" : "chevron.right", identifier: "island-question-next",
                           fill: ready ? color.allow : color.highlight, stroke: .clear,
                           foreground: ready ? color.onAllow : color.tertiary, trailing: !isLast, action: advance)
                .disabled(!ready)
        }
    }

    /// On to the next question once this one has an answer.
    private func advance() {
        guard draft.answer(page, of: question) != nil else { return }
        next()
    }

    /// The next question, or, after the last one, the answers given to the client.
    private func next() {
        if isLast { onDecide(.answer(draft.answers(for: questions))) } else { draft.page = page + 1 }
    }
}

/// The agent's words before its question, its Markdown drawn inline: the first four lines, and for longer words a way
/// to open the rest, which then scrolls within `maxHeight` so the question and its answers stay on the card.
private struct QuestionReplyText: View {
    let text: String
    let expanded: Bool
    let onToggle: () -> Void
    var maxHeight: CGFloat = 260
    @Environment(\.permissionColor) private var color

    /// Whether the words run past four lines at the card's width, as far as their length tells: about 55 characters a line.
    private var isLong: Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + 54) / 55) } > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expanded {
                CompletionReplyText(text: text, maxHeight: maxHeight, ink: color.secondary, size: 11,
                                    identifier: "island-question-reply")
            } else {
                Text(CompletionReplyText.markdown(text)).font(.ui(11)).foregroundStyle(color.secondary)
                    .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("island-question-reply")
            }
            if isLong || expanded {
                Button(action: onToggle) {
                    HStack(spacing: 3) {
                        Text(expanded ? L10n.text("收起", "Show less") : L10n.text("展开全文", "Show more"))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.ui(10, .medium)).foregroundStyle(color.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("island-question-reply-toggle")
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.inset, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// A question the client asks in its own window and takes no answer to from here, such as the Claude desktop app's
/// next-step box: what it asks, and the answers its window offers, listed to be given there. Putting the card away answers
/// nothing.
struct ClientQuestionCard: View {
    let request: PermissionRequest
    let onDecide: (PermissionDecision) -> Void
    @Environment(\.permissionColor) private var color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let recap = request.detail {
                Text(recap).font(.ui(11)).foregroundStyle(color.secondary)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(request.questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = question.header {
                        Text(header).font(.ui(10, .semibold)).foregroundStyle(color.tertiary)
                    }
                    Text(question.question).font(.ui(12, .semibold)).foregroundStyle(color.text)
                        .lineLimit(5).fixedSize(horizontal: false, vertical: true)
                    // A list rather than buttons: the window that asked takes the click.
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(color.tertiary)
                                Text(option.label).font(.ui(11, .medium)).foregroundStyle(color.secondary)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                            .help(option.description ?? option.label)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(L10n.text("请到 \(request.vendor) 里回答", "Answer in \(request.vendor)"))
                    .font(.ui(11)).foregroundStyle(color.secondary).lineLimit(1)
                Spacer(minLength: 8)
                QuestionButton(title: L10n.text("知道了", "Dismiss"), symbol: nil, identifier: "island-permission-dismiss",
                               fill: .clear, stroke: color.border, foreground: color.secondary) { onDecide(.leave) }
            }
        }
    }
}

struct QuestionButton: View {
    let title: String
    let symbol: String?
    let identifier: String
    let fill: Color
    let stroke: Color
    let foreground: Color
    /// A step forward reads with its arrow after the words.
    var trailing = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol, !trailing { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
                Text(title).font(.ui(11, .medium)).lineLimit(1)
                if let symbol, trailing { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9).frame(height: 22)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// A one-line field on the island.
///
/// The island never takes the keyboard on its own: a card arriving while the user types elsewhere must not catch
/// their keys. Clicking into the field is what hands the keyboard to the island, and it goes back the moment
/// typing ends — the answer is sent, Escape is pressed, or the user clicks somewhere else. Return while an input
/// method is still composing belongs to the input method; only a finished line is submitted.
///
/// Its text is drawn in the ink of the HUD it is on, and follows when that HUD's look changes, even mid-sentence. The
/// caret and the selection are AppKit's, and follow the island window's appearance.
struct IslandTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    var onFocus: () -> Void = {}
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onTyping: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> KeyboardField {
        let field = KeyboardField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        paint(field, context: context)
        field.stringValue = text
        field.onFocus = { [coordinator = context.coordinator] in coordinator.focused() }
        field.onBlur = { [coordinator = context.coordinator] field in coordinator.blurred(field) }
        return field
    }

    func updateNSView(_ field: KeyboardField, context: Context) {
        context.coordinator.parent = self
        paint(field, context: context)
        // The field owns its text while it is being edited; a redraw must not move the caret or break a composition.
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    /// Inks the text and the placeholder for the look of the HUD the field is on, and again only when that look changes.
    private func paint(_ field: KeyboardField, context: Context) {
        let look = context.environment.hudLook
        guard context.coordinator.look != look else { return }
        context.coordinator.look = look
        let color = PermissionColor(look.theme)
        field.textColor = NSColor(color.text)
        // Text being typed is drawn by the field editor, which took its colour from the field when the typing began.
        field.currentEditor()?.textColor = field.textColor
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(color.tertiary), .font: NSFont.systemFont(ofSize: 11),
        ])
    }

    static func dismantleNSView(_ field: KeyboardField, coordinator: Coordinator) {
        if coordinator.typing { coordinator.parent.onTyping(false) }
        (field.window as? OverlayPanel)?.releaseKeyboard()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: IslandTextField
        var typing = false
        /// The look the field was last inked for.
        var look: HUDLook?

        init(_ parent: IslandTextField) { self.parent = parent }

        /// Typing starts the moment the field has the caret, not at the first key: the island has to stay open
        /// for someone who clicked in and is still thinking.
        func focused() {
            parent.onFocus()
            guard !typing else { return }
            typing = true
            parent.onTyping(true)
        }

        func blurred(_ field: NSTextField) {
            guard typing else { return }
            typing = false
            parent.onTyping(false)
            (field.window as? OverlayPanel)?.releaseKeyboard()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard !textView.hasMarkedText() else { return false }
                parent.onChange(textView.string)
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// The field that asks the island for the keyboard when it is clicked, and says when it gets the caret and loses it.
final class KeyboardField: NSTextField {
    var onFocus: () -> Void = {}
    var onBlur: (NSTextField) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        (window as? OverlayPanel)?.takeKeyboard()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus() }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onBlur(self)
    }
}
