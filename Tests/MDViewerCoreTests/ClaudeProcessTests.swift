import Foundation
import Testing
@testable import MDViewerCore

struct ClaudeEnvironmentTests {
    @Test func dropsVariablesLeftByAParentClaudeSession() {
        let inherited = [
            "PATH": "/usr/bin", "HOME": "/Users/me", "ANTHROPIC_API_KEY": "key",
            "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH": "1",
            "CLAUDE_AGENT_SDK_VERSION": "0.3.299", "CLAUDE_EFFORT": "max",
        ]
        #expect(ShellEnvironment.withoutParentSession(inherited) == ["PATH": "/usr/bin", "HOME": "/Users/me", "ANTHROPIC_API_KEY": "key"])
    }

    @Test func terminalDoesNotInheritAParentClaudeSession() {
        let env = ShellEnvironment.terminalEnvironment(from: ["PATH": "/usr/bin", "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH": "1"])
        #expect(!env.contains { $0.hasPrefix("CLAUDE_CODE_") })
    }

    @Test func parsesTheEnvironmentPrintedByTheLoginShell() {
        let marker = ShellEnvironment.probeMarker
        let output = "motd\n\n\(marker)\nPATH=/opt/homebrew/bin:/usr/bin\u{0}NOTE=line1\nline2\u{0}EQUATION=a=b\u{0}\n\(marker)\nbye"
        #expect(ShellEnvironment.parseEnvironmentOutput(output) == ["PATH": "/opt/homebrew/bin:/usr/bin", "NOTE": "line1\nline2", "EQUATION": "a=b"])
        #expect(ShellEnvironment.parseEnvironmentOutput("zsh: something failed") == nil)
    }

    @Test func readsTheLoginShellsEnvironment() async throws {
        let env = try #require(await ShellEnvironment.loginEnvironment())
        #expect(env["PATH"]?.contains("/usr/bin") == true)
        #expect(env["HOME"] != nil)
        // These tests may run inside Claude Code; its session markers must not leak through.
        #expect(env["CLAUDECODE"] == nil)
        #expect(!env.keys.contains { $0.hasPrefix("CLAUDE_CODE_") })
    }

    @Test func findsCommandsOnThePathInOrder() throws {
        let folder = try TemporaryFolder()
        try folder.write("#!/bin/sh\n", to: "one/claude") // not executable: skipped
        let found = try folder.write("#!/bin/sh\n", to: "two/claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: found.path)
        let env = ["PATH": folder.url.appending(path: "one").path + ":" + folder.url.appending(path: "two").path, "HOME": "/nonexistent"]
        #expect(ShellEnvironment.findExecutable("claude", in: env) == found.path)
    }

    @Test func looksWhereClaudeCodesInstallersPutItWhenThePathMissesIt() throws {
        let home = try TemporaryFolder()
        let local = try home.write("#!/bin/sh\n", to: ".claude/local/claude") // older installs reach this through an alias
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: local.path)
        #expect(ShellEnvironment.findExecutable("claude", in: ["PATH": "/nonexistent", "HOME": home.url.path]) == local.path)
        #expect(ShellEnvironment.findExecutable("claude", in: ["PATH": "/nonexistent", "HOME": "/nonexistent"]) == nil)
    }
}

struct ClaudeLaunchTests {
    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @Test func speaksJSONLinesBothWaysAndAsksForApprovalsOverStdio() {
        let arguments = ClaudeLaunch.arguments(resumeSessionID: nil, model: nil)
        #expect(arguments.first == "-p")
        #expect(value(after: "--input-format", in: arguments) == "stream-json")
        #expect(value(after: "--output-format", in: arguments) == "stream-json")
        #expect(arguments.contains("--verbose")) // stream-json output requires it
        #expect(value(after: "--permission-prompt-tool", in: arguments) == "stdio")
        #expect(value(after: "--append-system-prompt", in: arguments)?.contains("<mdviewer-context>") == true)
    }

    @Test func resumesAnEarlierSessionAndUsesAChosenModel() {
        let fresh = ClaudeLaunch.arguments(resumeSessionID: nil, model: nil)
        let resumed = ClaudeLaunch.arguments(resumeSessionID: "s-1", model: "haiku")
        #expect(!fresh.contains("--resume") && !fresh.contains("--model"))
        #expect(value(after: "--resume", in: resumed) == "s-1")
        #expect(value(after: "--model", in: resumed) == "haiku")
    }

    @Test func turnsOffToolsThatNeedScreensTheChatDoesNotHave() {
        // The chat can't show Claude's question forms or plan approvals; Claude asks in plain text instead.
        let disallowed = value(after: "--disallowedTools", in: ClaudeLaunch.arguments(resumeSessionID: nil, model: nil)) ?? ""
        #expect(disallowed.contains("AskUserQuestion"))
        #expect(disallowed.contains("ExitPlanMode"))
    }

    @Test func runsWithUTF8Text() {
        #expect(ClaudeLaunch.environment(from: ["PATH": "/usr/bin"])["LANG"] == "en_US.UTF-8")
        #expect(ClaudeLaunch.environment(from: ["LANG": "he_IL.UTF-8"])["LANG"] == "he_IL.UTF-8")
    }
}

/// Collects a process's callbacks for a test.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [ClaudeEvent] = []
    let queue = DispatchQueue(label: "ClaudeProcessTests.callbacks")

    var events: [ClaudeEvent] { lock.withLock { collected } }
    func record(_ event: ClaudeEvent) { lock.withLock { collected.append(event) } }
}

/// Starts a process and waits for it to exit, after `drive` has talked to it.
private func run(_ process: (@escaping @Sendable (ClaudeEvent) -> Void, @escaping @Sendable (Int32, String) -> Void) -> ClaudeProcess,
                 drive: (ClaudeProcess) throws -> Void) async throws -> (events: [ClaudeEvent], status: Int32, errorOutput: String) {
    let recorder = Recorder()
    var started: ClaudeProcess?
    let (status, errorOutput) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, String), Error>) in
        let claude = process({ recorder.record($0) }, { continuation.resume(returning: ($0, $1)) })
        started = claude
        do {
            try claude.start()
            try drive(claude)
        } catch {
            continuation.resume(throwing: error)
        }
    }
    _ = started
    return (recorder.events, status, errorOutput)
}

struct ClaudeProcessTests {
    /// A stand-in for `claude`: prints shell noise, then answers each line it reads.
    static let fakeClaude = #"""
        #!/bin/bash
        printf 'shell noise\n'
        printf '{"type":"system","subtype":"init","session_id":"%s","model":"%s"}\n' "$PWD" "$1"
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*) printf '{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{}}}\n' ;;
            *'"type":"user"'*) printf '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"%s"}]},"parent_tool_use_id":null}\n' "$FAKE_REPLY"
                               printf '{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s1"}\n' ;;
          esac
        done
        echo "goodbye from fake claude" >&2
        exit 3
        """#

    private func script(_ text: String, in folder: TemporaryFolder) throws -> URL {
        let url = try folder.write(text, to: "bin/claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func runsClaudeInItsFolderAndPassesMessagesBothWays() async throws {
        let folder = try TemporaryFolder()
        let executable = try script(Self.fakeClaude, in: folder)
        let result = try await run({ onEvent, onExit in
            ClaudeProcess(executable: executable, arguments: ["first-arg"], environment: ["FAKE_REPLY": "שלום"],
                          directory: folder.url, callbackQueue: DispatchQueue(label: "test"), onEvent: onEvent, onExit: onExit)
        }, drive: { claude in
            claude.send(ClaudeInput.initialize(requestID: "init"))
            claude.send(ClaudeInput.userMessage("Hi"))
            claude.closeInput()
        })
        #expect(result.events == [
            .sessionStarted(sessionID: canonicalPath(folder.url), model: "first-arg"), // the script prints its working folder

            .requestAnswered(requestID: "init", error: nil),
            .assistantText(messageID: "m1", text: "שלום", parentToolUseID: nil),
            .turnFinished(TurnResult(isError: false, message: "done", sessionID: "s1")),
        ])
        #expect(result.status == 3)
        #expect(result.errorOutput.contains("goodbye from fake claude"))
    }

    @Test func ignoresMessagesSentAfterClaudeExited() async throws {
        let folder = try TemporaryFolder()
        let executable = try script("#!/bin/bash\nexit 1\n", in: folder)
        var finished: ClaudeProcess?
        let result = try await run({ onEvent, onExit in
            let claude = ClaudeProcess(executable: executable, arguments: [], environment: [:], directory: folder.url,
                                       callbackQueue: DispatchQueue(label: "test"), onEvent: onEvent, onExit: onExit)
            finished = claude
            return claude
        }, drive: { _ in })
        #expect(result.status == 1)
        let claude = try #require(finished)
        #expect(!claude.isRunning)
        // Writing to the closed pipe must not raise SIGPIPE, which would end the app.
        for _ in 0..<3 { claude.send(ClaudeInput.userMessage("Anyone there?")) }
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test func stopsClaudeWhenAsked() async throws {
        let folder = try TemporaryFolder()
        let executable = try script("#!/bin/bash\nwhile IFS= read -r line; do :; done\n", in: folder)
        let result = try await run({ onEvent, onExit in
            ClaudeProcess(executable: executable, arguments: [], environment: [:], directory: folder.url,
                          callbackQueue: DispatchQueue(label: "test"), onEvent: onEvent, onExit: onExit)
        }, drive: { claude in
            #expect(claude.isRunning)
            claude.terminate()
        })
        #expect(result.status == SIGTERM)
    }

    @Test func reportsAProgramThatCannotStart() throws {
        let claude = ClaudeProcess(executable: URL(fileURLWithPath: "/nonexistent/claude"), arguments: [], environment: [:],
                                   directory: URL(fileURLWithPath: "/tmp"), callbackQueue: DispatchQueue(label: "test"),
                                   onEvent: { _ in }, onExit: { _, _ in })
        #expect(throws: (any Error).self) { try claude.start() }
    }
}
