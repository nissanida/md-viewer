import CoreServices
import Foundation

/// Watches folders (recursively) with FSEvents and reports which paths changed.
///
/// FSEvents also catches tools that save by writing a temporary file and
/// renaming it over the original, which is how most editors and Claude Code
/// write files. A plain file descriptor watch would lose track of the file.
public final class FileWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (_ changedPaths: [String]) -> Void

    /// Owned by the FSEvents stream, so callbacks never outlive their handler.
    private final class Callback {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    public let paths: [String]
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "MDViewer.FileWatcher")
    // Only touched from the thread that calls start() and stop().
    private var stream: FSEventStreamRef?

    /// - Parameters:
    ///   - paths: folders to watch, including everything below them
    ///   - latency: how long FSEvents waits to group changes into one callback
    ///   - handler: called on a background queue with the canonical paths that changed
    public init(paths: [String], latency: TimeInterval = 0.1, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }

        let callback = Unmanaged.passRetained(Callback(handler)).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: callback,
            retain: nil,
            release: { info in
                if let info { Unmanaged<Callback>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let onEvents: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().handler(paths)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, onEvents, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else {
            Unmanaged<Callback>.fromOpaque(callback).release()
            return false
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
