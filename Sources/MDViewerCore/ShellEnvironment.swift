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
        var env = withoutParentSession(base)
        // Other leftovers from however the app itself was launched.
        for key in ["TERM_SESSION_ID", "TERM_PROGRAM_VERSION", "XPC_SERVICE_NAME", "__CFBundleIdentifier", "PWD", "OLDPWD", "SHLVL"] {
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

    /// Drops what a parent Claude Code session leaves in the environment when
    /// it launched the app (while developing it, for example). CLAUDECODE makes
    /// Claude Code refuse to start as a "nested" session, and the CLAUDE_CODE_*
    /// settings make it wait for its parent to refresh the login. Settings the
    /// user exports in their shell profile come back through the login shell.
    public static func withoutParentSession(_ env: [String: String]) -> [String: String] {
        env.filter { key, _ in key != "CLAUDECODE" && !key.hasPrefix("CLAUDE_") }
    }

    /// The environment a new Terminal window would have, from running the
    /// user's login shell once (with the parent session's leftovers removed).
    public static func loginEnvironment(shell: String = loginShell(), timeout: TimeInterval = 8) async -> [String: String]? {
        let script = "printf '\\n\(probeMarker)\\n'; /usr/bin/env -0; printf '\\n\(probeMarker)\\n'"
        let output = await runCapturingOutput(shell, ["-l", "-i", "-c", script], until: probeMarker, timeout: timeout)
        return parseEnvironmentOutput(output)
    }

    /// Reads the `env -0` output between the two markers: entries end with a
    /// NUL, so values may contain line breaks.
    static func parseEnvironmentOutput(_ output: String) -> [String: String]? {
        let parts = output.components(separatedBy: probeMarker)
        guard parts.count >= 3 else { return nil }
        var env: [String: String] = [:]
        for entry in parts[1].split(separator: "\u{0}") {
            let text = entry.hasPrefix("\n") ? entry.dropFirst() : entry
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            env[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return env.isEmpty ? nil : env
    }

    /// The first executable `name` on the environment's PATH, else in the
    /// folders Claude Code's installers use (an older install is reached
    /// through a shell alias, which the PATH doesn't show).
    public static func findExecutable(_ name: String, in env: [String: String]) -> String? {
        var candidates = (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + name }
        if let home = env["HOME"] {
            candidates += [home + "/.local/bin/" + name, home + "/.claude/local/" + name]
        }
        return candidates.first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
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
            var env = withoutParentSession(ProcessInfo.processInfo.environment)
            env["TERM"] = "dumb"
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

