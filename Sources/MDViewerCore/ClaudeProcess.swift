import Foundation

/// Runs `claude` in stream-json mode and carries JSON lines both ways.
/// Output lines are decoded into events and delivered in order on
/// `callbackQueue`; `onExit` comes after the last event, with the exit status
/// and the end of what Claude Code wrote to stderr.
public final class ClaudeProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writes = DispatchQueue(label: "MDViewer.ClaudeProcess.writes")
    private let callbackQueue: DispatchQueue
    private let onEvent: @Sendable (ClaudeEvent) -> Void
    private let onExit: @Sendable (Int32, String) -> Void

    private let lock = NSLock()
    // Guarded by `lock`:
    private var lines = LineBuffer()
    private var errorTail = Data()
    private var outputOpen = true
    /// The two things to wait for before reporting the exit: output closed, process ended.
    private var waitingFor = 2
    // Only used on `writes`:
    private var inputOpen = true

    static let errorTailLimit = 4096

    public init(executable: URL, arguments: [String], environment: [String: String], directory: URL, callbackQueue: DispatchQueue,
                onEvent: @escaping @Sendable (ClaudeEvent) -> Void, onExit: @escaping @Sendable (Int32, String) -> Void) {
        self.callbackQueue = callbackQueue
        self.onEvent = onEvent
        self.onExit = onExit
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        // A write after Claude Code exited fails quietly instead of raising
        // SIGPIPE, which would end the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { closeOutput() } else { deliver(lock.withLock { lines.append(data) }) }
        }
        errors.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { keepErrorOutput(data) }
        }
        process.terminationHandler = { [self] _ in
            finishOne()
            // A program Claude Code started may still hold the output open: don't wait for it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in closeOutput() }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw error
        }
    }

    /// Writes one message (a line from `ClaudeInput`). Ignored once Claude Code is gone.
    public func send(_ message: Data) {
        writes.async { [self] in
            guard inputOpen else { return }
            do {
                try input.fileHandleForWriting.write(contentsOf: message)
            } catch {
                inputOpen = false
            }
        }
    }

    /// Ends the input: Claude Code finishes its current request, then exits.
    public func closeInput() {
        writes.async { [self] in
            guard inputOpen else { return }
            inputOpen = false
            try? input.fileHandleForWriting.close()
        }
    }

    /// Ends Claude Code now (SIGTERM, so it can stop the programs it started).
    public func terminate() {
        if process.isRunning { process.terminate() }
        closeInput()
    }

    // MARK: Output

    private func deliver(_ lines: [Data]) {
        let events = lines.flatMap(ClaudeEvent.decode)
        guard !events.isEmpty else { return }
        callbackQueue.async { [onEvent] in events.forEach(onEvent) }
    }

    private func closeOutput() {
        let (wasOpen, last) = lock.withLock { () -> (Bool, Data?) in
            guard outputOpen else { return (false, nil) }
            outputOpen = false
            return (true, lines.finish())
        }
        guard wasOpen else { return }
        output.fileHandleForReading.readabilityHandler = nil
        if let last { deliver([last]) }
        finishOne()
    }

    private func keepErrorOutput(_ data: Data) {
        lock.withLock {
            errorTail.append(data)
            if errorTail.count > Self.errorTailLimit { errorTail = Data(errorTail.suffix(Self.errorTailLimit)) }
        }
    }

    private func finishOne() {
        let done = lock.withLock {
            waitingFor -= 1
            return waitingFor == 0
        }
        guard done else { return }
        let status = process.terminationStatus
        let errorText = lock.withLock { String(decoding: errorTail, as: UTF8.self) }
        callbackQueue.async { [onExit] in onExit(status, errorText) }
    }
}
