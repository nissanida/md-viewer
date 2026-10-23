import Foundation

/// What the chat tells Claude about the document with each message, and the
/// short file paths it shows people.
public enum ChatContext {
    /// Longer selections are cut: Claude can read the rest from the file.
    public static let selectionLimit = 4000

    /// A path for people to read: relative to the chat's folder when the file
    /// is inside it, else starting with "~" in the home folder, else in full.
    public static func displayPath(_ file: URL, folder: URL?) -> String {
        let path = file.standardizedFileURL.path(percentEncoded: false)
        if let folder, let relative = path.relative(to: folder.standardizedFileURL.path(percentEncoded: false)) {
            return relative
        }
        if let relative = path.relative(to: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)) {
            return "~/" + relative
        }
        return path
    }

    /// The user's message, after a block that names the open document, the
    /// selected text and an undone change. The system prompt explains the block.
    public static func message(_ text: String, document: URL?, folder: URL?, selection: String?, undoneDocument: URL?) -> String {
        var lines = ["<mdviewer-context>"]
        if let document {
            lines.append("Open document: \(displayPath(document, folder: folder))")
        } else {
            lines.append("No document is open.")
        }
        if let selection, selection.nonEmpty != nil {
            var quoted = selection
            if quoted.count > selectionLimit {
                quoted = String(quoted.prefix(selectionLimit)) + "\n[…the selection continues in the document]"
            }
            lines.append("Selected text:\n\"\"\"\n\(quoted)\n\"\"\"")
        }
        if let undoneDocument {
            lines.append("The user undid your last change to \(displayPath(undoneDocument, folder: folder)), so it is back to how it was before that change.")
        }
        lines.append("</mdviewer-context>")
        return lines.joined(separator: "\n") + "\n\n" + text
    }
}

extension String {
    /// The string, or nil when it is empty or only whitespace.
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    /// This path relative to `folder`, or nil when it isn't inside it.
    /// "/a/project2/x" is not inside "/a/project".
    func relative(to folder: String) -> String? {
        var base = folder
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        guard hasPrefix(base + "/") else { return nil }
        return String(dropFirst(base.count + 1))
    }
}
