import Foundation
import Testing
@testable import MDViewerCore

/// Lines as Claude Code prints them in stream-json mode. The init, error and
/// result lines are trimmed copies of real output from Claude Code 2.1.158.
private func line(_ text: String) -> Data { Data(text.utf8) }

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

struct JSONValueTests {
    @Test func readsNestedValues() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: line(#"{"a":{"b":[1,"x",true,null]},"n":2.5}"#))
        #expect(value["a"]?["b"]?[1]?.string == "x")
        #expect(value["a"]?["b"]?[2]?.bool == true)
        #expect(value["a"]?["b"]?[3] == .null)
        #expect(value["n"]?.number == 2.5)
        #expect(value["missing"] == nil)
        #expect(value["n"]?.string == nil)
    }

    @Test func writesNumbersAndBooleansBackUnchanged() throws {
        let text = #"{"command":"ls -1","limit":10,"replace_all":false,"nested":{"list":["a"]}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: line(text))
        let written = try object(JSONEncoder().encode(value))
        #expect(written["command"] as? String == "ls -1")
        #expect(written["limit"] as? Int == 10)
        #expect((written["replace_all"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true)
        #expect((written["nested"] as? [String: Any])?["list"] as? [String] == ["a"])
    }
}

struct LineBufferTests {
    @Test func keepsAPartialLineUntilItsEndArrives() {
        var buffer = LineBuffer()
        #expect(buffer.append(line("{\"a\":1}\n{\"b\"")) == [line("{\"a\":1}")])
        #expect(buffer.append(line(":2}\n")) == [line("{\"b\":2}")])
        #expect(buffer.finish() == nil)
    }

    @Test func joinsACharacterSplitAcrossReads() {
        let hebrew = Data("שלום\n".utf8)
        var buffer = LineBuffer()
        #expect(buffer.append(hebrew.prefix(3)).isEmpty) // ends inside the second letter
        let lines = buffer.append(hebrew.dropFirst(3))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["שלום"])
    }

    @Test func dropsCarriageReturnsAndHandsOverTheRestAtTheEnd() {
        var buffer = LineBuffer()
        #expect(buffer.append(line("one\r\n\ntwo")) == [line("one"), Data()])
        #expect(buffer.finish() == line("two"))
    }
}

struct ClaudeEventTests {
    @Test func readsTheSessionFromInit() {
        let events = ClaudeEvent.decode(line(#"{"type":"system","subtype":"init","cwd":"/Users/me/notes","session_id":"s-1","tools":["Read","Edit"],"mcp_servers":[],"model":"claude-opus-4-8","permissionMode":"default","slash_commands":[],"apiKeySource":"none","claude_code_version":"2.1.158","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u-1"}"#))
        #expect(events == [.sessionStarted(sessionID: "s-1", model: "claude-opus-4-8")])
    }

    @Test func readsTextAsItIsWritten() {
        let start = ClaudeEvent.decode(line(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-4-8","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":1}}},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-2"}"#))
        let block = ClaudeEvent.decode(line(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-3"}"#))
        let delta = ClaudeEvent.decode(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"שלום, "}},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-4"}"#))
        #expect(start == [.messageStarted(messageID: "msg_1", parentToolUseID: nil)])
        #expect(block == [.textBlockStarted(parentToolUseID: nil)])
        #expect(delta == [.textDelta("שלום, ", parentToolUseID: nil)])
    }

    @Test func ignoresThinkingAndToolInputAsItStreams() {
        let lines = [
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-5"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me"}},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-6"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"Edit","input":{}}},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-7"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"file_"}},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-8"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":1},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-9"}"#,
        ]
        #expect(lines.flatMap { ClaudeEvent.decode(line($0)) } == [])
    }

    @Test func readsTextAndToolCallsFromAFinishedMessage() {
        let events = ClaudeEvent.decode(line(#"{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-4-8","content":[{"type":"text","text":"I'll add it."},{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"/Users/me/notes/list.md","old_string":"- bread","new_string":"- bread\n- eggs"}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":40}},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-10"}"#))
        let input: JSONValue = .object([
            "file_path": .string("/Users/me/notes/list.md"), "old_string": .string("- bread"), "new_string": .string("- bread\n- eggs"),
        ])
        #expect(events == [
            .assistantText(messageID: "msg_1", text: "I'll add it.", parentToolUseID: nil),
            .toolUse(ToolUse(id: "toolu_1", name: "Edit", input: input, parentToolUseID: nil)),
        ])
    }

    @Test func marksWorkDoneByHelperAgents() {
        let text = ClaudeEvent.decode(line(#"{"type":"assistant","message":{"id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Searching."}]},"parent_tool_use_id":"toolu_9","session_id":"s-1","uuid":"u-11"}"#))
        let delta = ClaudeEvent.decode(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Sea"}},"parent_tool_use_id":"toolu_9","session_id":"s-1","uuid":"u-12"}"#))
        #expect(text == [.assistantText(messageID: "msg_2", text: "Searching.", parentToolUseID: "toolu_9")])
        #expect(delta == [.textDelta("Sea", parentToolUseID: "toolu_9")])
    }

    @Test func readsToolResultsAndWhetherTheyFailed() {
        let events = ClaudeEvent.decode(line(#"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"The file /Users/me/notes/list.md has been updated."},{"type":"tool_result","tool_use_id":"toolu_2","content":"The user declined this action.","is_error":true}]},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-13","timestamp":"2026-10-23T15:00:00.000Z"}"#))
        #expect(events == [.toolResult(toolUseID: "toolu_1", isError: false), .toolResult(toolUseID: "toolu_2", isError: true)])
    }

    @Test func readsApprovalRequests() {
        let events = ClaudeEvent.decode(line(#"{"type":"control_request","request_id":"req-7","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls -1","description":"List files"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ls:*"}],"behavior":"allow","destination":"localSettings"}],"tool_use_id":"toolu_3"}}"#))
        let input: JSONValue = .object(["command": .string("ls -1"), "description": .string("List files")])
        #expect(events == [.approvalRequested(ApprovalRequest(requestID: "req-7", toolName: "Bash", input: input, toolUseID: "toolu_3"))])
    }

    @Test func readsWithdrawnApprovalRequests() {
        #expect(ClaudeEvent.decode(line(#"{"type":"control_cancel_request","request_id":"req-7"}"#)) == [.approvalWithdrawn(requestID: "req-7")])
    }

    @Test func readsAnswersToTheAppsOwnRequests() {
        let success = ClaudeEvent.decode(line(#"{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{"commands":[],"account":{"tokenSource":"none","apiProvider":"firstParty"},"pid":41671}}}"#))
        let failure = ClaudeEvent.decode(line(#"{"type":"control_response","response":{"subtype":"error","request_id":"stop-2","error":"No query in progress"}}"#))
        #expect(success == [.requestAnswered(requestID: "init", error: nil)])
        #expect(failure == [.requestAnswered(requestID: "stop-2", error: "No query in progress")])
    }

    @Test func readsTheModelsClaudeCodeOffers() {
        // Trimmed from Claude Code 2.1.158's answer to initialize, signed in with a Pro plan.
        let events = ClaudeEvent.decode(line(#"{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{"commands":[],"models":[{"value":"default","displayName":"Default (recommended)","description":"Sonnet 4.6 · Best for everyday tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},{"value":"opus","displayName":"Opus","description":"Opus 4.8 · Most capable for complex work · ~2× usage vs Sonnet","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsFastMode":true,"supportsAutoMode":true},{"value":"haiku","displayName":"Haiku","description":"Haiku 4.5 · Fastest for quick answers"}],"account":{"subscriptionType":"Claude Pro"},"pid":51234}}}"#))
        #expect(events == [
            .requestAnswered(requestID: "init", error: nil),
            .modelsAvailable([
                ClaudeModel(value: "default", displayName: "Default (recommended)", description: "Sonnet 4.6 · Best for everyday tasks",
                            effortLevels: ["low", "medium", "high", "max"], supportsAutoMode: true),
                ClaudeModel(value: "opus", displayName: "Opus", description: "Opus 4.8 · Most capable for complex work · ~2× usage vs Sonnet",
                            effortLevels: ["low", "medium", "high", "xhigh", "max"], supportsAutoMode: true),
                ClaudeModel(value: "haiku", displayName: "Haiku", description: "Haiku 4.5 · Fastest for quick answers",
                            effortLevels: [], supportsAutoMode: false),
            ]),
        ])
    }

    @Test func turnsDownRequestKindsTheAppDoesNotHandle() {
        let events = ClaudeEvent.decode(line(#"{"type":"control_request","request_id":"req-8","request":{"subtype":"hook_callback","callback_id":"hook_0","input":{}}}"#))
        #expect(events == [.unsupportedRequest(requestID: "req-8", subtype: "hook_callback")])
    }

    @Test func readsErrorsThatArriveAsAssistantMessages() {
        // Real output when Claude Code isn't signed in.
        let events = ClaudeEvent.decode(line(#"{"type":"assistant","message":{"id":"c6f9e4eb-073a-47be-b290-7ebe60a3d436","container":null,"model":"<synthetic>","role":"assistant","stop_details":null,"stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"Not logged in · Please run /login"}]},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u-14","error":"authentication_failed"}"#))
        #expect(events == [.failed(kind: "authentication_failed", message: "Not logged in · Please run /login")])
    }

    @Test func readsTheEndOfARequest() {
        let done = ClaudeEvent.decode(line(#"{"type":"result","subtype":"success","is_error":false,"duration_ms":2300,"duration_api_ms":2100,"num_turns":2,"result":"Added eggs to the list.","stop_reason":"end_turn","session_id":"s-1","total_cost_usd":0.0012,"usage":{"input_tokens":10,"output_tokens":40},"permission_denials":[],"terminal_reason":"completed","uuid":"u-15"}"#))
        let failed = ClaudeEvent.decode(line(#"{"type":"result","subtype":"success","is_error":true,"api_error_status":null,"duration_ms":37,"duration_api_ms":0,"num_turns":1,"result":"Not logged in · Please run /login","stop_reason":"stop_sequence","session_id":"s-1","total_cost_usd":0,"permission_denials":[],"terminal_reason":"completed","uuid":"u-16"}"#))
        #expect(done == [.turnFinished(TurnResult(isError: false, message: "Added eggs to the list.", sessionID: "s-1"))])
        #expect(failed == [.turnFinished(TurnResult(isError: true, message: "Not logged in · Please run /login", sessionID: "s-1"))])
    }

    @Test func skipsLinesThatAreNotMessagesForTheChat() {
        let lines = [
            "",
            "Last login: Fri Oct 23 on ttys001",
            #"{"type":"system","subtype":"status","status":"requesting","uuid":"u-17","session_id":"s-1"}"#,
            #"{"type":"system","subtype":"hook_started","hook_id":"h","hook_name":"SessionStart:startup","hook_event":"SessionStart","uuid":"u-18","session_id":"s-1"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"echoed prompt"}]},"parent_tool_use_id":null,"session_id":"s-1"}"#,
            "[1,2,3]",
        ]
        #expect(lines.flatMap { ClaudeEvent.decode(line($0)) } == [])
    }
}

struct ClaudeInputTests {
    @Test func writesOneMessagePerLine() {
        for message in [ClaudeInput.userMessage("Fix\nthis"), ClaudeInput.initialize(requestID: "init"), ClaudeInput.interrupt(requestID: "stop-1")] {
            #expect(message.last == UInt8(ascii: "\n"))
            #expect(message.dropLast().contains(UInt8(ascii: "\n")) == false)
        }
    }

    @Test func sendsTheUserMessageAsText() throws {
        let message = try object(ClaudeInput.userMessage("Make it shorter\nplease"))
        #expect(message["type"] as? String == "user")
        #expect(message["parent_tool_use_id"] is NSNull)
        let body = try #require(message["message"] as? [String: Any])
        #expect(body["role"] as? String == "user")
        let content = try #require(body["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "Make it shorter\nplease")
    }

    @Test func allowsAToolWithItsOriginalInput() throws {
        let input: JSONValue = .object(["file_path": .string("/Users/me/a.md"), "replace_all": .bool(false)])
        let message = try object(ClaudeInput.allow(requestID: "req-7", input: input))
        #expect(message["type"] as? String == "control_response")
        let response = try #require(message["response"] as? [String: Any])
        #expect(response["subtype"] as? String == "success")
        #expect(response["request_id"] as? String == "req-7")
        let decision = try #require(response["response"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let updated = try #require(decision["updatedInput"] as? [String: Any])
        #expect(updated["file_path"] as? String == "/Users/me/a.md")
        #expect(updated["replace_all"] as? Bool == false)
    }

    @Test func deniesAToolWithAReason() throws {
        let message = try object(ClaudeInput.deny(requestID: "req-8", message: "The user declined.", interrupt: true))
        let response = try #require(message["response"] as? [String: Any])
        #expect(response["request_id"] as? String == "req-8")
        let decision = try #require(response["response"] as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == "The user declined.")
        #expect(decision["interrupt"] as? Bool == true)
    }

    @Test func asksToInitializeAndToInterrupt() throws {
        let initialize = try object(ClaudeInput.initialize(requestID: "init"))
        let interrupt = try object(ClaudeInput.interrupt(requestID: "stop-1"))
        #expect(initialize["type"] as? String == "control_request")
        #expect(initialize["request_id"] as? String == "init")
        #expect((initialize["request"] as? [String: Any])?["subtype"] as? String == "initialize")
        #expect(interrupt["request_id"] as? String == "stop-1")
        #expect((interrupt["request"] as? [String: Any])?["subtype"] as? String == "interrupt")
    }

    @Test func turnsDownUnsupportedRequests() throws {
        let message = try object(ClaudeInput.unsupported(requestID: "req-8", subtype: "hook_callback"))
        let response = try #require(message["response"] as? [String: Any])
        #expect(response["subtype"] as? String == "error")
        #expect(response["request_id"] as? String == "req-8")
        #expect((response["error"] as? String)?.contains("hook_callback") == true)
    }
}
