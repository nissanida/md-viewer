import Foundation

// Claude Code's stream-json protocol, as the chat panel uses it. Claude Code
// runs as `claude -p --input-format stream-json --output-format stream-json`:
// it prints one JSON message per line and reads one per line. See
// docs/CHAT_DESIGN.md for the whole exchange.

/// A tool call in one of Claude's messages.
public struct ToolUse: Equatable, Sendable {
    public let id: String
    public let name: String
    public let input: JSONValue
    /// Set when a helper agent (Claude's Task tool) made the call.
    public let parentToolUseID: String?

    public init(id: String, name: String, input: JSONValue, parentToolUseID: String?) {
        self.id = id
        self.name = name
        self.input = input
        self.parentToolUseID = parentToolUseID
    }
}

/// Claude Code asking whether a tool may run (`can_use_tool`).
public struct ApprovalRequest: Equatable, Sendable {
    public let requestID: String
    public let toolName: String
    public let input: JSONValue
    public let toolUseID: String?

    public init(requestID: String, toolName: String, input: JSONValue, toolUseID: String?) {
        self.requestID = requestID
        self.toolName = toolName
        self.input = input
        self.toolUseID = toolUseID
    }
}

/// How a request (one user message and Claude's work on it) ended.
public struct TurnResult: Equatable, Sendable {
    public let isError: Bool
    /// Claude's final text, or the error message.
    public let message: String?
    public let sessionID: String?

    public init(isError: Bool, message: String?, sessionID: String?) {
        self.isError = isError
        self.message = message
        self.sessionID = sessionID
    }
}

/// What a line of Claude Code's output means for the chat.
public enum ClaudeEvent: Equatable, Sendable {
    case sessionStarted(sessionID: String, model: String?)
    /// A new message from Claude began streaming.
    case messageStarted(messageID: String, parentToolUseID: String?)
    /// A block of text began streaming in the current message.
    case textBlockStarted(parentToolUseID: String?)
    case textDelta(String, parentToolUseID: String?)
    /// A finished block of text (the streamed text, complete).
    case assistantText(messageID: String, text: String, parentToolUseID: String?)
    case toolUse(ToolUse)
    case toolResult(toolUseID: String, isError: Bool)
    case approvalRequested(ApprovalRequest)
    /// Claude Code no longer needs an answer (for example, after Stop).
    case approvalWithdrawn(requestID: String)
    /// The answer to a request the app sent (initialize, interrupt).
    case requestAnswered(requestID: String, error: String?)
    /// A request the app must turn down, so Claude Code doesn't wait for it.
    case unsupportedRequest(requestID: String, subtype: String)
    /// Claude Code couldn't answer, for example because it isn't signed in.
    case failed(kind: String, message: String)
    case turnFinished(TurnResult)

    /// The events in one line of output. Lines that aren't messages (shell
    /// noise) and messages the chat doesn't show give none.
    public static func decode(_ line: Data) -> [ClaudeEvent] {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { return [] }
        let parent = message["parent_tool_use_id"]?.string
        switch message["type"]?.string {
        case "system":
            guard message["subtype"]?.string == "init", let session = message["session_id"]?.string else { return [] }
            return [.sessionStarted(sessionID: session, model: message["model"]?.string)]
        case "stream_event":
            return streamEvent(message["event"], parent: parent)
        case "assistant":
            return assistantMessage(message, parent: parent)
        case "user":
            return (message["message"]?["content"]?.array ?? []).compactMap { block in
                guard block["type"]?.string == "tool_result", let id = block["tool_use_id"]?.string else { return nil }
                return .toolResult(toolUseID: id, isError: block["is_error"]?.bool ?? false)
            }
        case "control_request":
            guard let id = message["request_id"]?.string, let request = message["request"] else { return [] }
            let subtype = request["subtype"]?.string ?? ""
            if subtype == "can_use_tool", let tool = request["tool_name"]?.string {
                let approval = ApprovalRequest(requestID: id, toolName: tool, input: request["input"] ?? [:],
                                               toolUseID: request["tool_use_id"]?.string)
                return [.approvalRequested(approval)]
            }
            return [.unsupportedRequest(requestID: id, subtype: subtype)]
        case "control_cancel_request":
            guard let id = message["request_id"]?.string else { return [] }
            return [.approvalWithdrawn(requestID: id)]
        case "control_response":
            guard let response = message["response"], let id = response["request_id"]?.string else { return [] }
            let error = response["subtype"]?.string == "error" ? (response["error"]?.string ?? "The request failed.") : nil
            return [.requestAnswered(requestID: id, error: error)]
        case "result":
            let result = TurnResult(isError: message["is_error"]?.bool ?? false, message: message["result"]?.string,
                                    sessionID: message["session_id"]?.string)
            return [.turnFinished(result)]
        default:
            return []
        }
    }

    private static func streamEvent(_ event: JSONValue?, parent: String?) -> [ClaudeEvent] {
        guard let event else { return [] }
        switch event["type"]?.string {
        case "message_start":
            guard let id = event["message"]?["id"]?.string else { return [] }
            return [.messageStarted(messageID: id, parentToolUseID: parent)]
        case "content_block_start":
            guard event["content_block"]?["type"]?.string == "text" else { return [] }
            let initial = event["content_block"]?["text"]?.string ?? ""
            return [.textBlockStarted(parentToolUseID: parent)] + (initial.isEmpty ? [] : [.textDelta(initial, parentToolUseID: parent)])
        case "content_block_delta":
            guard event["delta"]?["type"]?.string == "text_delta", let text = event["delta"]?["text"]?.string else { return [] }
            return [.textDelta(text, parentToolUseID: parent)]
        default:
            return []
        }
    }

    private static func assistantMessage(_ message: JSONValue, parent: String?) -> [ClaudeEvent] {
        let content = message["message"]?["content"]?.array ?? []
        // Errors (not signed in, API errors) come as a made-up assistant message.
        if let kind = message["error"]?.string {
            let text = content.compactMap { $0["text"]?.string }.joined(separator: "\n")
            return [.failed(kind: kind, message: text)]
        }
        let messageID = message["message"]?["id"]?.string ?? ""
        return content.compactMap { block in
            switch block["type"]?.string {
            case "text":
                guard let text = block["text"]?.string else { return nil }
                return .assistantText(messageID: messageID, text: text, parentToolUseID: parent)
            case "tool_use":
                guard let id = block["id"]?.string, let name = block["name"]?.string else { return nil }
                return .toolUse(ToolUse(id: id, name: name, input: block["input"] ?? [:], parentToolUseID: parent))
            default:
                return nil
            }
        }
    }
}

/// Messages the app writes to Claude Code, one JSON line each.
public enum ClaudeInput {
    /// The first message, before any user message (as Anthropic's SDKs do).
    public static func initialize(requestID: String) -> Data {
        JSONValue.object(["type": "control_request", "request_id": .string(requestID), "request": ["subtype": "initialize"]]).line
    }

    public static func userMessage(_ text: String) -> Data {
        let content: JSONValue = [["type": "text", "text": .string(text)]]
        let message: JSONValue = [
            "type": "user", "session_id": "", "parent_tool_use_id": nil,
            "message": ["role": "user", "content": content],
        ]
        return message.line
    }

    /// Lets the tool run with the input Claude asked for.
    public static func allow(requestID: String, input: JSONValue) -> Data {
        answer(requestID, ["behavior": "allow", "updatedInput": input])
    }

    /// Refuses the tool. With `interrupt`, Claude also stops working on the request.
    public static func deny(requestID: String, message: String, interrupt: Bool) -> Data {
        answer(requestID, ["behavior": "deny", "message": .string(message), "interrupt": .bool(interrupt)])
    }

    /// Stops the request Claude is working on; the session stays open.
    public static func interrupt(requestID: String) -> Data {
        JSONValue.object(["type": "control_request", "request_id": .string(requestID), "request": ["subtype": "interrupt"]]).line
    }

    public static func unsupported(requestID: String, subtype: String) -> Data {
        let response: JSONValue = [
            "subtype": "error", "request_id": .string(requestID),
            "error": .string("MD Viewer doesn't handle \(subtype) requests."),
        ]
        return JSONValue.object(["type": "control_response", "response": response]).line
    }

    private static func answer(_ requestID: String, _ decision: JSONValue) -> Data {
        let response: JSONValue = ["subtype": "success", "request_id": .string(requestID), "response": decision]
        return JSONValue.object(["type": "control_response", "response": response]).line
    }
}
