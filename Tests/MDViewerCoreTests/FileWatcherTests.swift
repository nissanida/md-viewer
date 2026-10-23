import Foundation
import Testing
@testable import MDViewerCore

/// Collects the paths a FileWatcher reports, from its background queue.
private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func record(_ changed: [String]) {
        lock.lock(); paths += changed; lock.unlock()
    }

    func reset() {
        lock.lock(); paths.removeAll(); lock.unlock()
    }

    func contains(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths.contains(path)
    }

    /// Polls until `path` was reported or the timeout passes.
    func waitFor(_ path: String, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if contains(path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return contains(path)
    }
}

@Suite(.serialized)
struct FileWatcherTests {
    private func watch(_ folder: TemporaryFolder) async throws -> (FileWatcher, ChangeLog) {
        let log = ChangeLog()
        let watcher = FileWatcher(paths: [canonicalPath(folder.url)], latency: 0.05) { log.record($0) }
        #expect(watcher.start())
        // Let FSEvents deliver anything from before the test step (such as the
        // setup files being created), then forget it so only the step counts.
        try await Task.sleep(for: .milliseconds(500))
        log.reset()
        return (watcher, log)
    }

    @Test func reportsAnInPlaceEdit() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("# One", to: "note.md")
        let (watcher, log) = try await watch(folder)
        defer { watcher.stop() }

        try "# Two".write(to: file, atomically: false, encoding: .utf8)
        #expect(await log.waitFor(canonicalPath(file)))
    }

    @Test func reportsAnAtomicReplace() async throws {
        // Editors and Claude Code write a temporary file, then rename it over the original.
        let folder = try TemporaryFolder()
        let file = try folder.write("# One", to: "note.md")
        let (watcher, log) = try await watch(folder)
        defer { watcher.stop() }

        try "# Two".write(to: file, atomically: true, encoding: .utf8)
        #expect(await log.waitFor(canonicalPath(file)))
    }

    @Test func reportsFilesInSubfolders() async throws {
        let folder = try TemporaryFolder()
        let (watcher, log) = try await watch(folder)
        defer { watcher.stop() }

        let file = try folder.write("new", to: "docs/guide/new.md")
        #expect(await log.waitFor(canonicalPath(file)))
    }

    @Test func reportsDeletion() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("bye", to: "gone.md")
        let path = canonicalPath(file)
        let (watcher, log) = try await watch(folder)
        defer { watcher.stop() }

        try FileManager.default.removeItem(at: file)
        #expect(await log.waitFor(path))
    }

    @Test func staysQuietAfterStop() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("a", to: "note.md")
        let (watcher, log) = try await watch(folder)
        watcher.stop()

        try "b".write(to: file, atomically: false, encoding: .utf8)
        #expect(await log.waitFor(canonicalPath(file), timeout: .milliseconds(600)) == false)
    }
}

struct ReloadPolicyTests {
    @Test func ignoresUnchangedContent() {
        #expect(ReloadPolicy.decide(diskContent: "a", lastLoaded: "a", hasUnsavedEdits: true) == .ignore)
    }

    @Test func reloadsWhenThereAreNoEdits() {
        #expect(ReloadPolicy.decide(diskContent: "b", lastLoaded: "a", hasUnsavedEdits: false) == .reload("b"))
    }

    @Test func asksBeforeReplacingUnsavedEdits() {
        #expect(ReloadPolicy.decide(diskContent: "b", lastLoaded: "a", hasUnsavedEdits: true) == .conflict("b"))
    }

    @Test func reportsDeletedFiles() {
        #expect(ReloadPolicy.decide(diskContent: nil, lastLoaded: "a", hasUnsavedEdits: false) == .deleted)
    }
}
