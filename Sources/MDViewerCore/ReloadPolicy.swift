import Foundation

/// What to do after the open file changed on disk.
public enum ReloadDecision: Equatable, Sendable {
    /// Nothing changed (for example, the app's own save, or a touch).
    case ignore
    /// Show the new content; there are no unsaved edits to lose.
    case reload(String)
    /// The file changed while the user has unsaved edits: ask before replacing them.
    case conflict(String)
    /// The file is gone (deleted, or moved away).
    case deleted
}

public enum ReloadPolicy {
    /// - Parameters:
    ///   - diskContent: the file's content now, or nil if it no longer exists
    ///   - lastLoaded: the content the app last read from or wrote to disk
    ///   - hasUnsavedEdits: whether the editor holds changes not yet saved
    public static func decide(diskContent: String?, lastLoaded: String, hasUnsavedEdits: Bool) -> ReloadDecision {
        guard let diskContent else { return .deleted }
        if diskContent == lastLoaded { return .ignore }
        return hasUnsavedEdits ? .conflict(diskContent) : .reload(diskContent)
    }
}
