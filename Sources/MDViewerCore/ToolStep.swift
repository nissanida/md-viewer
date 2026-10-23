import Foundation

/// A tool call described in plain words, as one line in the chat.
public struct ToolStep: Equatable, Sendable {
    public enum Icon: String, Sendable, Codable { case read, edit, run, search, web, agent, other }

    public var icon: Icon
    public var text: String
    /// A command or search pattern, shown in a code font.
    public var code: String?
    /// The full path or address, shown on hover.
    public var detail: String?

    public init(icon: Icon, text: String, code: String? = nil, detail: String? = nil) {
        self.icon = icon
        self.text = text
        self.code = code
        self.detail = detail
    }

    /// Claude's own bookkeeping (its to-do list, looking up tools): nothing the reader needs.
    static let hidden: Set<String> = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskOutput", "TaskStop", "ToolSearch"]

    /// The line for a tool call, or nil for steps the chat leaves out.
    public static func describe(name: String, input: JSONValue, folder: URL?) -> ToolStep? {
        if hidden.contains(name) { return nil }
        let file = input["file_path"]?.string ?? input["notebook_path"]?.string
        switch name {
        case "Read":
            return fileStep(.read, "Read", file, folder)
        case "Edit", "MultiEdit", "NotebookEdit":
            return fileStep(.edit, "Edit", file, folder)
        case "Write":
            return fileStep(.edit, "Write", file, folder)
        case "Bash":
            return ToolStep(icon: .run, text: input["description"]?.string?.nonEmpty ?? "Run a command", code: input["command"]?.string)
        case "Grep":
            return ToolStep(icon: .search, text: "Search files", code: input["pattern"]?.string)
        case "Glob":
            return ToolStep(icon: .search, text: "Find files", code: input["pattern"]?.string)
        case "WebSearch":
            return ToolStep(icon: .web, text: "Search the web" + forQuery(input))
        case "WebFetch":
            let url = input["url"]?.string
            return ToolStep(icon: .web, text: "Open " + (host(url) ?? "a web page"), detail: url)
        case "Task", "Agent":
            return ToolStep(icon: .agent, text: input["description"]?.string?.nonEmpty.map { "Ask a helper: \($0)" } ?? "Ask a helper")
        case "Skill":
            return ToolStep(icon: .other, text: "Use " + skillName(input))
        default:
            return ToolStep(icon: .other, text: "Use " + toolName(name))
        }
    }

    /// The question for an approval banner.
    public static func question(name: String, input: JSONValue, folder: URL?) -> ApprovalQuestion {
        let file = (input["file_path"]?.string ?? input["notebook_path"]?.string)
            .map { ChatContext.displayPath(URL(fileURLWithPath: $0), folder: folder) } ?? "a file"
        switch name {
        case "Bash":
            return ApprovalQuestion(text: "Allow Claude to run this command?", code: input["command"]?.string)
        case "Edit", "MultiEdit", "NotebookEdit":
            return ApprovalQuestion(text: "Allow Claude to edit \(file)?")
        case "Write":
            return ApprovalQuestion(text: "Allow Claude to write \(file)?")
        case "Read":
            return ApprovalQuestion(text: "Allow Claude to read \(file)?")
        case "Grep", "Glob":
            let place = input["path"]?.string?.nonEmpty.map { "in " + ChatContext.displayPath(URL(fileURLWithPath: $0), folder: folder) } ?? "files"
            return ApprovalQuestion(text: "Allow Claude to search \(place)?", code: input["pattern"]?.string)
        case "WebFetch":
            return ApprovalQuestion(text: "Allow Claude to open \(host(input["url"]?.string) ?? "a web page")?")
        case "WebSearch":
            return ApprovalQuestion(text: "Allow Claude to search the web\(forQuery(input))?")
        case "Skill":
            return ApprovalQuestion(text: "Allow Claude to use \(skillName(input))?")
        default:
            return ApprovalQuestion(text: "Allow Claude to use \(toolName(name))?")
        }
    }

    private static func fileStep(_ icon: Icon, _ verb: String, _ file: String?, _ folder: URL?) -> ToolStep {
        guard let file else { return ToolStep(icon: icon, text: "\(verb) a file") }
        return ToolStep(icon: icon, text: "\(verb) \(ChatContext.displayPath(URL(fileURLWithPath: file), folder: folder))", detail: file)
    }

    private static func forQuery(_ input: JSONValue) -> String {
        input["query"]?.string?.nonEmpty.map { " for “\($0)”" } ?? ""
    }

    private static func skillName(_ input: JSONValue) -> String {
        input["skill"]?.string?.nonEmpty.map { "the \($0) skill" } ?? "a skill"
    }

    private static func host(_ url: String?) -> String? {
        url.flatMap { URL(string: $0)?.host() }
    }

    /// "mcp__github__create_issue" reads as "create_issue (github)".
    private static func toolName(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return name }
        return "\(parts[2...].joined(separator: "__")) (\(parts[1]))"
    }
}

/// What an approval banner asks, with the command it is about (if any).
public struct ApprovalQuestion: Equatable, Sendable {
    public var text: String
    public var code: String?

    public init(text: String, code: String? = nil) {
        self.text = text
        self.code = code
    }
}
