import Foundation

/// The user's shell setup, as Terminal.app would see it.
///
/// Apps opened from Finder get a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
/// so tools installed with Homebrew, npm or Claude Code's installer are missing.
/// The terminal panel therefore starts the user's shell as a login shell, which
/// loads their profile and PATH exactly like Terminal.app does.
public enum ShellEnvironment {
    /// The user's login shell from the account database (more reliable than $SHELL in GUI apps).
    public static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Environment for the terminal panel's shell, as `KEY=value` strings.
    public static func terminalEnvironment(from base: [String: String]) -> [String] {
        var env = base
        // Leftovers from however the app itself was launched. CLAUDECODE in
        // particular makes Claude Code refuse to start ("nested session").
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TERM_SESSION_ID", "TERM_PROGRAM_VERSION",
                    "XPC_SERVICE_NAME", "__CFBundleIdentifier", "PWD", "OLDPWD", "SHLVL"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "MDViewer"
        env["SHELL"] = loginShell()
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        // Without a UTF-8 locale, shells mangle non-ASCII text (Hebrew, emoji, Claude Code's symbols).
        if !(env["LANG"] ?? "").uppercased().contains("UTF-8") { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// How the user's shell resolves `command` (a path, an alias or a function),
    /// or nil if it does not. Runs an interactive login shell once, so it sees the
    /// same PATH and aliases as a new Terminal window.
    public static func resolveCommand(_ command: String, shell: String = loginShell(), timeout: TimeInterval = 8) async -> String? {
        guard command.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        let script = "printf '\\n\(probeMarker)\\n'; command -v \(command); printf '\\n\(probeMarker)\\n'"
        let output = await runCapturingOutput(shell, ["-l", "-i", "-c", script], until: probeMarker, timeout: timeout)
        return parseProbeOutput(output)
    }

    static let probeMarker = "__MDVIEWER_PROBE__"

    /// Takes the text between the two markers; shell startup files may print other text around it.
    static func parseProbeOutput(_ output: String) -> String? {
        let parts = output.components(separatedBy: probeMarker)
        guard parts.count >= 3 else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Runs a program and returns its output once `marker` has appeared twice, the
    /// program exits, or the timeout passes. Waiting for EOF alone could hang if a
    /// startup file leaves a background process holding the pipe open.
    static func runCapturingOutput(_ executable: String, _ arguments: [String], until marker: String, timeout: TimeInterval) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "dumb"
            env.removeValue(forKey: "CLAUDECODE")
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            let collector = OutputCollector(marker: marker) { output in
                pipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                continuation.resume(returning: output)
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { collector.finish() } else { collector.append(data) }
            }
            do {
                try process.run()
            } catch {
                collector.finish()
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { collector.finish() }
        }
    }
}

/// Collects a process's output and calls `onFinish` exactly once.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    private let marker: Data
    private let onFinish: @Sendable (String) -> Void

    init(marker: String, onFinish: @escaping @Sendable (String) -> Void) {
        self.marker = Data(marker.utf8)
        self.onFinish = onFinish
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        let complete = Self.count(of: marker, in: data) >= 2
        lock.unlock()
        if complete { finish() }
    }

    func finish() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let output = String(decoding: data, as: UTF8.self)
        lock.unlock()
        onFinish(output)
    }

    private static func count(of needle: Data, in haystack: Data) -> Int {
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, in: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
