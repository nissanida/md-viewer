import Foundation

/// One entry in the chat: the user's message, a reply, a tool step or a notice.
public struct ChatItem: Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case user, assistant, step, notice }
    public enum State: String, Sendable, Codable { case running, done, failed, denied, stopped }
    public enum Tone: String, Sendable, Codable { case info, error }

    public let id: String
    public let kind: Kind
    public var text: String
    /// User messages: the selected text that was sent along.
    public var quote: String?
    /// Replies: still being written.
    public var streaming: Bool
    /// Steps: what kind of step, its command or pattern, and its full path or address.
    public var icon: ToolStep.Icon?
    public var code: String?
    public var detail: String?
    public var state: State?
    /// Notices: information or an error.
    public var tone: Tone?

    public init(id: String, kind: Kind, text: String, quote: String? = nil, streaming: Bool = false, icon: ToolStep.Icon? = nil,
                code: String? = nil, detail: String? = nil, state: State? = nil, tone: Tone? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.quote = quote
        self.streaming = streaming
        self.icon = icon
        self.code = code
        self.detail = detail
        self.state = state
        self.tone = tone
    }
}

/// The chat as the user sees it, built from Claude Code's events. Replies
/// stream in as they are written, tool calls become one-line steps, and the
/// inner work of helper agents and Claude's bookkeeping are left out.
///
/// Each change returns the items it added or changed, so the page can update
/// just those.
public struct ChatTranscript: Sendable {
    public private(set) var items: [ChatItem] = []
    /// The chat's working folder, for short paths in steps.
    public var folder: URL?

    private var nextNumber = 1
    private var currentMessageID: String?
    /// Text blocks of the current request that are streaming or waiting for their final text.
    private var drafts: [Draft] = []
    private var stepIDs: [String: String] = [:] // tool use id -> item id
    private var turnHadError = false

    private struct Draft: Sendable {
        var messageID: String?
        var itemID: String?
    }

    static let genericError = "Claude couldn't finish this request."

    public init(folder: URL?) {
        self.folder = folder
    }

    public mutating func addUserMessage(_ text: String, quote: String?) -> ChatItem {
        turnHadError = false
        drafts.removeAll()
        return add(ChatItem(id: makeID("u"), kind: .user, text: text, quote: quote))
    }

    public mutating func addNotice(_ text: String, tone: ChatItem.Tone) -> ChatItem {
        add(ChatItem(id: makeID("n"), kind: .notice, text: text, tone: tone))
    }

    public mutating func apply(_ event: ClaudeEvent) -> [ChatItem] {
        switch event {
        case .messageStarted(let id, .none):
            currentMessageID = id
            return []
        case .textBlockStarted(.none):
            drafts.append(Draft(messageID: currentMessageID))
            return []
        case .textDelta(let text, .none):
            return [appendToDraft(text)]
        case .assistantText(let messageID, let text, .none):
            return settleDraft(messageID: messageID, text: text)
        case .toolUse(let use) where use.parentToolUseID == nil:
            guard let step = ToolStep.describe(name: use.name, input: use.input, folder: folder) else { return [] }
            let item = add(ChatItem(id: makeID("s"), kind: .step, text: step.text, icon: step.icon, code: step.code,
                                    detail: step.detail, state: .running))
            stepIDs[use.id] = item.id
            return [item]
        case .toolResult(let toolUseID, let isError):
            return update(stepIDs[toolUseID], where: { $0.state == .running }) { $0.state = isError ? .failed : .done }
        case .failed(_, let message):
            turnHadError = true
            return [addNotice(message.nonEmpty ?? Self.genericError, tone: .error)]
        default:
            return []
        }
    }

    /// The user refused a step, so its error result must not show it as failed.
    public mutating func markDenied(toolUseID: String) -> [ChatItem] {
        update(stepIDs[toolUseID], where: { $0.state == .running }) { $0.state = .denied }
    }

    /// Ends the request: settles text still streaming and steps still running,
    /// and explains how it ended if that isn't already shown.
    /// - Parameter result: nil when Claude Code stopped without reporting one.
    public mutating func finishTurn(_ result: TurnResult?, stoppedByUser: Bool) -> [ChatItem] {
        var changed: [ChatItem] = []
        for draft in drafts {
            changed += update(draft.itemID) { $0.streaming = false }
        }
        drafts.removeAll()
        for index in items.indices where items[index].kind == .step && items[index].state == .running {
            items[index].state = .stopped
            changed.append(items[index])
        }
        if stoppedByUser {
            changed.append(addNotice("Stopped.", tone: .info))
        } else if let result, result.isError, !turnHadError {
            changed.append(addNotice(result.message?.nonEmpty ?? Self.genericError, tone: .error))
        }
        turnHadError = false
        currentMessageID = nil
        return changed
    }

    public mutating func reset() {
        items.removeAll()
        drafts.removeAll()
        stepIDs.removeAll()
        currentMessageID = nil
        turnHadError = false
    }

    // MARK: Helpers

    private mutating func appendToDraft(_ text: String) -> ChatItem {
        if drafts.isEmpty { drafts.append(Draft(messageID: currentMessageID)) }
        let last = drafts.count - 1
        if let itemID = drafts[last].itemID, let index = index(of: itemID) {
            items[index].text += text
            return items[index]
        }
        let item = add(ChatItem(id: makeID("a"), kind: .assistant, text: text, streaming: true))
        drafts[last].itemID = item.id
        return item
    }

    /// The finished text of a block replaces what streamed for it.
    private mutating func settleDraft(messageID: String, text: String) -> [ChatItem] {
        let match = drafts.firstIndex { $0.messageID == messageID } ?? drafts.firstIndex { $0.messageID == nil }
        let itemID = match.flatMap { drafts[$0].itemID }
        if let match { drafts.remove(at: match) }
        if let itemID, let index = index(of: itemID) {
            items[index].text = text
            items[index].streaming = false
            return [items[index]]
        }
        guard text.nonEmpty != nil else { return [] }
        return [add(ChatItem(id: makeID("a"), kind: .assistant, text: text))]
    }

    private mutating func update(_ itemID: String?, where condition: (ChatItem) -> Bool = { _ in true },
                                 _ change: (inout ChatItem) -> Void) -> [ChatItem] {
        guard let itemID, let index = index(of: itemID), condition(items[index]) else { return [] }
        change(&items[index])
        return [items[index]]
    }

    private mutating func add(_ item: ChatItem) -> ChatItem {
        items.append(item)
        return item
    }

    private mutating func makeID(_ prefix: String) -> String {
        defer { nextNumber += 1 }
        return prefix + String(nextNumber)
    }

    private func index(of id: String) -> Int? {
        items.firstIndex { $0.id == id }
    }
}
