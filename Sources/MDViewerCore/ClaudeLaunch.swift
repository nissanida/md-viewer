import Foundation

/// How the chat starts Claude Code: its arguments, its environment, and the
/// instructions that make it an assistant for the open document.
public enum ClaudeLaunch {
    /// Tools that need a screen the chat doesn't have (question forms, plan
    /// approval, worktrees) or that schedule work outside the conversation.
    /// Without the question form, Claude asks in plain text.
    static let disallowedTools = [
        "AskUserQuestion", "EnterPlanMode", "ExitPlanMode", "EnterWorktree", "ExitWorktree",
        "CronCreate", "CronDelete", "CronList", "ScheduleWakeup", "RemoteTrigger", "PushNotification", "Monitor",
    ]

    static let systemPrompt = """
        You are running inside MD Viewer, an app for reading and lightly editing markdown and HTML \
        documents. The person you are talking to is reading a document and asks you, in plain words, \
        to change it or to answer questions about it. They may not be a programmer.

        Each of their messages starts with an <mdviewer-context> block that names the document they \
        have open, the text they selected (if any), and whether they undid your last change. Requests \
        refer to that document unless they say otherwise.

        - Make requested changes directly in the file with your editing tools. Keep the document's \
        language, writing direction and formatting.
        - They see the document update as you edit it, so reply in one or two short sentences that say \
        what you changed. Don't paste the edited text or a diff unless they ask for it.
        - Requests are usually small and direct: do them right away, without plans or confirmations. \
        If a request is genuinely unclear, ask one short question in plain text.
        - Reply in the language they write in.
        """

    public static func arguments(resumeSessionID: String?, model: String?) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", "default",
            "--append-system-prompt", systemPrompt,
            "--disallowedTools", disallowedTools.joined(separator: ","),
        ]
        if let resumeSessionID { arguments += ["--resume", resumeSessionID] }
        if let model { arguments += ["--model", model] }
        return arguments
    }

    /// Claude Code's environment: the login shell's, minus the shell's own
    /// bookkeeping, with a UTF-8 locale so Hebrew and emoji survive.
    public static func environment(from login: [String: String]) -> [String: String] {
        var env = login
        for key in ["PWD", "OLDPWD", "SHLVL", "_"] { env.removeValue(forKey: key) }
        if !(env["LANG"] ?? "").uppercased().contains("UTF-8") { env["LANG"] = "en_US.UTF-8" }
        return env
    }
}
