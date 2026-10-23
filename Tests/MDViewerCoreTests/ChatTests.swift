import Foundation
import Testing
@testable import MDViewerCore

private let notes = URL(fileURLWithPath: "/Users/me/notes")
private let home = FileManager.default.homeDirectoryForCurrentUser

struct ChatPathTests {
    @Test func namesFilesRelativeToTheChatFolder() {
        #expect(ChatContext.displayPath(URL(fileURLWithPath: "/Users/me/notes/docs/guide.md"), folder: notes) == "docs/guide.md")
        #expect(ChatContext.displayPath(URL(fileURLWithPath: "/Users/me/notes/a.md"), folder: URL(fileURLWithPath: "/Users/me/notes/")) == "a.md")
    }

    @Test func spellsOutFilesOutsideTheFolder() {
        #expect(ChatContext.displayPath(URL(fileURLWithPath: "/Users/me/notes2/a.md"), folder: notes) == "/Users/me/notes2/a.md")
        #expect(ChatContext.displayPath(home.appending(path: "Desktop/a.md"), folder: notes) == "~/Desktop/a.md")
        #expect(ChatContext.displayPath(URL(fileURLWithPath: "/tmp/a.md"), folder: nil) == "/tmp/a.md")
    }
}

struct ToolStepTests {
    @Test func describesFileStepsWithShortPaths() {
        let edit = ToolStep.describe(name: "Edit", input: ["file_path": "/Users/me/notes/docs/guide.md", "old_string": "a", "new_string": "b"], folder: notes)
        let read = ToolStep.describe(name: "Read", input: ["file_path": "/Users/me/notes/a.md"], folder: notes)
        let write = ToolStep.describe(name: "Write", input: ["file_path": "/tmp/new.md", "content": "x"], folder: notes)
        #expect(edit == ToolStep(icon: .edit, text: "Edit docs/guide.md", detail: "/Users/me/notes/docs/guide.md"))
        #expect(read == ToolStep(icon: .read, text: "Read a.md", detail: "/Users/me/notes/a.md"))
        #expect(write == ToolStep(icon: .edit, text: "Write /tmp/new.md", detail: "/tmp/new.md"))
    }

    @Test func showsTheCommandOfShellSteps() {
        let described = ToolStep.describe(name: "Bash", input: ["command": "ls -1", "description": "List files"], folder: notes)
        let bare = ToolStep.describe(name: "Bash", input: ["command": "git status"], folder: notes)
        #expect(described == ToolStep(icon: .run, text: "List files", code: "ls -1"))
        #expect(bare == ToolStep(icon: .run, text: "Run a command", code: "git status"))
    }

    @Test func describesSearchesAndWebPages() {
        #expect(ToolStep.describe(name: "Grep", input: ["pattern": "TODO", "path": "/Users/me/notes"], folder: notes) == ToolStep(icon: .search, text: "Search files", code: "TODO"))
        #expect(ToolStep.describe(name: "Glob", input: ["pattern": "**/*.md"], folder: notes) == ToolStep(icon: .search, text: "Find files", code: "**/*.md"))
        #expect(ToolStep.describe(name: "WebSearch", input: ["query": "markdown tables"], folder: notes) == ToolStep(icon: .web, text: "Search the web for “markdown tables”"))
        #expect(ToolStep.describe(name: "WebFetch", input: ["url": "https://example.com/a/b", "prompt": "Summarize"], folder: notes) == ToolStep(icon: .web, text: "Open example.com", detail: "https://example.com/a/b"))
    }

    @Test func describesHelpersSkillsAndUnknownTools() {
        #expect(ToolStep.describe(name: "Task", input: ["description": "Find related notes", "prompt": "…", "subagent_type": "Explore"], folder: notes) == ToolStep(icon: .agent, text: "Ask a helper: Find related notes"))
        #expect(ToolStep.describe(name: "Agent", input: ["description": "Check links"], folder: notes) == ToolStep(icon: .agent, text: "Ask a helper: Check links"))
        #expect(ToolStep.describe(name: "Skill", input: ["skill": "humanizer"], folder: notes) == ToolStep(icon: .other, text: "Use the humanizer skill"))
        #expect(ToolStep.describe(name: "mcp__github__create_issue", input: [:], folder: notes) == ToolStep(icon: .other, text: "Use create_issue (github)"))
        #expect(ToolStep.describe(name: "BrandNewTool", input: [:], folder: notes) == ToolStep(icon: .other, text: "Use BrandNewTool"))
    }

    @Test func hidesBookkeeping() {
        for name in ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskOutput", "TaskStop", "ToolSearch"] {
            #expect(ToolStep.describe(name: name, input: [:], folder: notes) == nil, "\(name)")
        }
    }

    @Test func asksForApprovalInPlainWords() {
        #expect(ToolStep.question(name: "Bash", input: ["command": "rm -rf build"], folder: notes) == ApprovalQuestion(text: "Allow Claude to run this command?", code: "rm -rf build"))
        #expect(ToolStep.question(name: "Edit", input: ["file_path": "/Users/me/notes/other.md"], folder: notes) == ApprovalQuestion(text: "Allow Claude to edit other.md?"))
        #expect(ToolStep.question(name: "Write", input: ["file_path": "/Users/me/notes/new.md"], folder: notes) == ApprovalQuestion(text: "Allow Claude to write new.md?"))
        #expect(ToolStep.question(name: "Read", input: ["file_path": "/etc/hosts"], folder: notes) == ApprovalQuestion(text: "Allow Claude to read /etc/hosts?"))
        #expect(ToolStep.question(name: "WebFetch", input: ["url": "https://example.com/x"], folder: notes) == ApprovalQuestion(text: "Allow Claude to open example.com?"))
        #expect(ToolStep.question(name: "WebSearch", input: ["query": "tides"], folder: notes) == ApprovalQuestion(text: "Allow Claude to search the web for “tides”?"))
        #expect(ToolStep.question(name: "Grep", input: ["pattern": "key", "path": "/etc"], folder: notes) == ApprovalQuestion(text: "Allow Claude to search in /etc?", code: "key"))
        #expect(ToolStep.question(name: "Skill", input: ["skill": "pdf"], folder: notes) == ApprovalQuestion(text: "Allow Claude to use the pdf skill?"))
        #expect(ToolStep.question(name: "mcp__notion__search", input: [:], folder: notes) == ApprovalQuestion(text: "Allow Claude to use search (notion)?"))
    }
}

struct ChatPermissionPolicyTests {
    @Test func allowsReadingAndEditingTheOpenDocument() throws {
        let folder = try TemporaryFolder()
        let document = try folder.write("# Hi", to: "guide.md")
        for tool in ["Read", "Edit", "MultiEdit", "Write"] {
            #expect(ChatPermissionPolicy.allowsWithoutAsking(toolName: tool, input: ["file_path": .string(document.path)], openDocument: document), "\(tool)")
        }
    }

    @Test func asksForOtherFilesOtherToolsAndUnclearPaths() throws {
        let folder = try TemporaryFolder()
        let document = try folder.write("# Hi", to: "guide.md")
        let other = try folder.write("# Other", to: "other.md")
        #expect(!ChatPermissionPolicy.allowsWithoutAsking(toolName: "Edit", input: ["file_path": .string(other.path)], openDocument: document))
        #expect(!ChatPermissionPolicy.allowsWithoutAsking(toolName: "Bash", input: ["command": .string("sed -i '' s/a/b/ \(document.path)")], openDocument: document))
        #expect(!ChatPermissionPolicy.allowsWithoutAsking(toolName: "Edit", input: ["file_path": "guide.md"], openDocument: document))
        #expect(!ChatPermissionPolicy.allowsWithoutAsking(toolName: "Edit", input: ["file_path": .string(document.path)], openDocument: nil))
        #expect(!ChatPermissionPolicy.allowsWithoutAsking(toolName: "Edit", input: [:], openDocument: document))
    }

    @Test func recognizesTheDocumentThroughALinkedFolder() throws {
        let folder = try TemporaryFolder()
        let document = try folder.write("# Hi", to: "real/guide.md")
        try FileManager.default.createSymbolicLink(at: folder.url.appending(path: "link"), withDestinationURL: folder.url.appending(path: "real"))
        let viaLink = folder.url.appending(path: "link/guide.md").path(percentEncoded: false)
        #expect(ChatPermissionPolicy.allowsWithoutAsking(toolName: "Edit", input: ["file_path": .string(viaLink)], openDocument: document))
    }
}

struct ChatContextTests {
    @Test func startsTheMessageWithTheDocumentAndTheSelection() {
        let text = ChatContext.message("Make this shorter", document: URL(fileURLWithPath: "/Users/me/notes/docs/guide.md"),
                                       folder: notes, selection: "A long\nparagraph.", undoneDocument: nil)
        #expect(text.hasPrefix("<mdviewer-context>\n"))
        #expect(text.contains("Open document: docs/guide.md\n"))
        #expect(text.contains("A long\nparagraph."))
        #expect(!text.contains("undid"))
        #expect(text.hasSuffix("</mdviewer-context>\n\nMake this shorter"))
    }

    @Test func saysWhenNoDocumentIsOpen() {
        let text = ChatContext.message("Hi", document: nil, folder: notes, selection: nil, undoneDocument: nil)
        #expect(text.contains("No document is open."))
        #expect(!text.contains("Selected text"))
    }

    @Test func mentionsAChangeTheUserUndid() {
        let text = ChatContext.message("Try again", document: URL(fileURLWithPath: "/Users/me/notes/a.md"), folder: notes,
                                       selection: nil, undoneDocument: URL(fileURLWithPath: "/Users/me/notes/a.md"))
        #expect(text.contains("The user undid your last change to a.md"))
    }

    @Test func ignoresAnEmptySelectionAndShortensAHugeOne() {
        let blank = ChatContext.message("Hi", document: nil, folder: notes, selection: "  \n ", undoneDocument: nil)
        #expect(!blank.contains("Selected text"))

        let huge = String(repeating: "a", count: ChatContext.selectionLimit) + "TAIL"
        let text = ChatContext.message("Hi", document: nil, folder: notes, selection: huge, undoneDocument: nil)
        #expect(text.contains(String(repeating: "a", count: ChatContext.selectionLimit)))
        #expect(!text.contains("TAIL"))
        #expect(text.contains("selection continues"))
    }
}

struct ChatTranscriptTests {
    private func step(_ transcript: ChatTranscript, _ id: String) -> ChatItem? {
        transcript.items.first { $0.id == id }
    }

    @Test func addsTheUsersMessageWithTheirSelection() {
        var transcript = ChatTranscript(folder: notes)
        let item = transcript.addUserMessage("Shorter please", quote: "Long text")
        #expect(item.kind == .user)
        #expect(item.text == "Shorter please")
        #expect(item.quote == "Long text")
        #expect(transcript.items == [item])
    }

    @Test func streamsTextIntoOneReplyThenSettlesIt() throws {
        var transcript = ChatTranscript(folder: notes)
        _ = transcript.apply(.messageStarted(messageID: "m1", parentToolUseID: nil))
        _ = transcript.apply(.textBlockStarted(parentToolUseID: nil))
        let first = transcript.apply(.textDelta("Hel", parentToolUseID: nil))
        let second = transcript.apply(.textDelta("lo", parentToolUseID: nil))
        let reply = try #require(first.first)
        #expect(reply.kind == .assistant && reply.text == "Hel" && reply.streaming)
        #expect(second.map(\.id) == [reply.id])
        #expect(second.first?.text == "Hello")

        let settled = transcript.apply(.assistantText(messageID: "m1", text: "Hello.", parentToolUseID: nil))
        #expect(settled.map(\.id) == [reply.id])
        #expect(settled.first?.text == "Hello.")
        #expect(settled.first?.streaming == false)
        #expect(transcript.items.count == 1)
    }

    @Test func keepsTextBeforeAndAfterAToolCallApart() {
        var transcript = ChatTranscript(folder: notes)
        let events: [ClaudeEvent] = [
            .messageStarted(messageID: "m1", parentToolUseID: nil),
            .textBlockStarted(parentToolUseID: nil), .textDelta("First.", parentToolUseID: nil),
            .assistantText(messageID: "m1", text: "First.", parentToolUseID: nil),
            .toolUse(ToolUse(id: "t1", name: "Read", input: ["file_path": "/Users/me/notes/a.md"], parentToolUseID: nil)),
            .toolResult(toolUseID: "t1", isError: false),
            .messageStarted(messageID: "m2", parentToolUseID: nil),
            .textBlockStarted(parentToolUseID: nil), .textDelta("Second.", parentToolUseID: nil),
            .assistantText(messageID: "m2", text: "Second.", parentToolUseID: nil),
        ]
        for event in events { _ = transcript.apply(event) }
        #expect(transcript.items.map(\.kind) == [.assistant, .step, .assistant])
        #expect(transcript.items.map(\.text) == ["First.", "Read a.md", "Second."])
    }

    @Test func showsTextThatArrivesWithoutStreaming() {
        var transcript = ChatTranscript(folder: notes)
        let added = transcript.apply(.assistantText(messageID: "m1", text: "Done.", parentToolUseID: nil))
        #expect(added.map(\.text) == ["Done."])
        #expect(added.first?.streaming == false)
        #expect(transcript.apply(.assistantText(messageID: "m1", text: "  ", parentToolUseID: nil)).isEmpty)
    }

    @Test func turnsToolCallsIntoStepsAndMarksHowTheyEnded() throws {
        var transcript = ChatTranscript(folder: notes)
        let edit = try #require(transcript.apply(.toolUse(ToolUse(id: "t1", name: "Edit", input: ["file_path": "/Users/me/notes/a.md"], parentToolUseID: nil))).first)
        let run = try #require(transcript.apply(.toolUse(ToolUse(id: "t2", name: "Bash", input: ["command": "make"], parentToolUseID: nil))).first)
        #expect(edit.kind == .step && edit.state == .running && edit.icon == .edit)
        #expect(transcript.apply(.toolResult(toolUseID: "t1", isError: false)).first?.state == .done)
        #expect(transcript.apply(.toolResult(toolUseID: "t2", isError: true)).first?.state == .failed)
        #expect(step(transcript, run.id)?.state == .failed)
        #expect(transcript.apply(.toolResult(toolUseID: "unknown", isError: false)).isEmpty)
    }

    @Test func leavesOutWorkDoneByHelperAgentsAndBookkeeping() {
        var transcript = ChatTranscript(folder: notes)
        let events: [ClaudeEvent] = [
            .textBlockStarted(parentToolUseID: "t9"), .textDelta("inner", parentToolUseID: "t9"),
            .assistantText(messageID: "m5", text: "inner", parentToolUseID: "t9"),
            .toolUse(ToolUse(id: "t10", name: "Read", input: ["file_path": "/x"], parentToolUseID: "t9")),
            .toolUse(ToolUse(id: "t11", name: "TodoWrite", input: [:], parentToolUseID: nil)),
            .toolResult(toolUseID: "t11", isError: false),
        ]
        for event in events { #expect(transcript.apply(event).isEmpty) }
        #expect(transcript.items.isEmpty)
    }

    @Test func keepsADeniedStepDenied() throws {
        var transcript = ChatTranscript(folder: notes)
        let run = try #require(transcript.apply(.toolUse(ToolUse(id: "t1", name: "Bash", input: ["command": "rm x"], parentToolUseID: nil))).first)
        #expect(transcript.markDenied(toolUseID: "t1").first?.state == .denied)
        #expect(transcript.apply(.toolResult(toolUseID: "t1", isError: true)).isEmpty)
        #expect(step(transcript, run.id)?.state == .denied)
    }

    @Test func showsAnErrorOnceEvenWhenTheResultRepeatsIt() {
        var transcript = ChatTranscript(folder: notes)
        _ = transcript.addUserMessage("Hi", quote: nil)
        let error = transcript.apply(.failed(kind: "authentication_failed", message: "Not logged in · Please run /login"))
        #expect(error.map(\.kind) == [.notice])
        #expect(error.first?.tone == .error)
        #expect(error.first?.text == "Not logged in · Please run /login")
        let ended = transcript.finishTurn(TurnResult(isError: true, message: "Not logged in · Please run /login", sessionID: "s"), stoppedByUser: false)
        #expect(ended.isEmpty)
        #expect(transcript.items.filter { $0.kind == .notice }.count == 1)
    }

    @Test func reportsAFailedRequestThatGaveNoEarlierError() {
        var transcript = ChatTranscript(folder: notes)
        _ = transcript.addUserMessage("Hi", quote: nil)
        let ended = transcript.finishTurn(TurnResult(isError: true, message: "API Error: 500", sessionID: nil), stoppedByUser: false)
        #expect(ended.map(\.text) == ["API Error: 500"])
        #expect(ended.first?.tone == .error)

        _ = transcript.addUserMessage("Again", quote: nil)
        let unexplained = transcript.finishTurn(TurnResult(isError: true, message: nil, sessionID: nil), stoppedByUser: false)
        #expect(unexplained.first?.tone == .error)
        #expect(unexplained.first?.text.isEmpty == false)
    }

    @Test func settlesUnfinishedWorkWhenTheUserStops() throws {
        var transcript = ChatTranscript(folder: notes)
        _ = transcript.addUserMessage("Rewrite it", quote: nil)
        _ = transcript.apply(.textBlockStarted(parentToolUseID: nil))
        let reply = try #require(transcript.apply(.textDelta("Partial", parentToolUseID: nil)).first)
        let run = try #require(transcript.apply(.toolUse(ToolUse(id: "t1", name: "Bash", input: ["command": "sleep 9"], parentToolUseID: nil))).first)
        let ended = transcript.finishTurn(TurnResult(isError: true, message: "Request interrupted", sessionID: "s"), stoppedByUser: true)
        #expect(step(transcript, reply.id)?.streaming == false)
        #expect(step(transcript, run.id)?.state == .stopped)
        #expect(ended.contains { $0.id == reply.id } && ended.contains { $0.id == run.id })
        let notices = transcript.items.filter { $0.kind == .notice }
        #expect(notices.count == 1)
        #expect(notices.first?.tone == .info)
    }

    @Test func startsOverEmpty() {
        var transcript = ChatTranscript(folder: notes)
        let old = transcript.addUserMessage("Hi", quote: nil)
        transcript.reset()
        #expect(transcript.items.isEmpty)
        #expect(transcript.addUserMessage("Hello", quote: nil).id != old.id)
    }
}

struct ChatSettingsTests {
    // As Claude Code 2.1.158 lists them for a Pro plan.
    private let models = [
        ClaudeModel(value: "default", displayName: "Default (recommended)", description: "Sonnet 4.6 · Best for everyday tasks",
                    effortLevels: ["low", "medium", "high", "max"], supportsAutoMode: true),
        ClaudeModel(value: "opus", displayName: "Opus", description: "Opus 4.8 · Most capable for complex work",
                    effortLevels: ["low", "medium", "high", "xhigh", "max"], supportsAutoMode: true),
        ClaudeModel(value: "haiku", displayName: "Haiku", description: "Haiku 4.5 · Fastest for quick answers",
                    effortLevels: [], supportsAutoMode: false),
    ]

    @Test func startsLikeClaudeCodesOwnDefaults() {
        #expect(ChatSettings().launchOptions(models: models) == LaunchOptions())
    }

    @Test func passesTheModelAndEffortTheUserChose() {
        let settings = ChatSettings(model: "opus", effort: "xhigh", autoMode: true)
        #expect(settings.launchOptions(models: models) == LaunchOptions(model: "opus", effort: "xhigh", autoMode: true))
    }

    @Test func leavesOutWhatTheChosenModelCannotDo() {
        // Haiku has no effort levels and no Auto mode; Default stops at "max", without "xhigh".
        #expect(ChatSettings(model: "haiku", effort: "high", autoMode: true).launchOptions(models: models) == LaunchOptions(model: "haiku"))
        #expect(ChatSettings(model: "default", effort: "xhigh", autoMode: false).launchOptions(models: models) == LaunchOptions())
    }

    @Test func trustsTheChoicesUntilClaudeCodeHasListedItsModels() {
        let settings = ChatSettings(model: "opus", effort: "high", autoMode: true)
        #expect(settings.launchOptions(models: []) == LaunchOptions(model: "opus", effort: "high", autoMode: true))
    }
}
