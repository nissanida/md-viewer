import Foundation

/// Which of Claude's tool requests the chat answers without asking: reading
/// and editing the open document, which the user asked about and can undo.
/// Everything else (other files, commands, the web) is shown to the user.
public enum ChatPermissionPolicy {
    static let documentTools: Set<String> = ["Read", "Edit", "MultiEdit", "Write"]

    public static func allowsWithoutAsking(toolName: String, input: JSONValue, openDocument: URL?) -> Bool {
        guard documentTools.contains(toolName), let openDocument,
              let path = input["file_path"]?.string, path.hasPrefix("/") else { return false }
        // Compare resolved paths, so a document opened through a linked folder still matches.
        return canonicalPath(URL(fileURLWithPath: path)) == canonicalPath(openDocument)
    }
}
