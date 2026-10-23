# Document chat: design

**Status:** built on branch `feature/document-chat` (2026-10-23), tested with a
stand-in for Claude Code and live with real Claude.

## Goal

Let a user change the open document by asking in plain words, in a chat
panel next to it. MD Viewer stays a reader with light editing; the chat must
not turn it into a code editor. Claude Code still runs underneath, with the
user's own account, settings, skills and CLAUDE.md.

**Success looks like:** open a document, type "make the intro shorter", watch
the preview change, and put it back with one click if you don't like it.

## Scope

In the first version:

- A chat panel on the right (View → Show Chat, ⌃⌘C, or the toolbar button with
  the Claude symbol: see D-014 about publishing it).
- Claude always gets the open document's path and the selected text, if any.
- Replies render as markdown, with Hebrew and Arabic reading right to left.
- Each tool step is one plain line ("Edited guide.md", "Ran a command").
- Edits to the open document apply without asking. **Undo** puts the file
  back as it was before Claude's last change.
- Anything else (other files, commands, web pages) asks **Allow / Deny**.
- **Stop** ends the current request; **New Chat** starts over.
- A clear notice when Claude Code isn't installed or isn't signed in.

- Under the message box: the model (as Claude Code lists them for the
  account), the effort (only the levels that model supports), and Auto mode
  on or off (only for models that support it). Remembered between launches;
  a change applies from the next message by restarting Claude Code with
  `--resume`, so the conversation continues.

Left out on purpose: file pickers, slash commands, diff views, chat history
across launches, pasted images.

## How it works

```
ChatPanelController (AppKit)          the panel: header, transcript, banners, input
 ├─ ChatTranscriptView (WKWebView)    display only, renders items with render.js
 ├─ ChatSession (Core)                state: transcript items, pending approvals, turn status
 └─ ClaudeProcess (Core)              runs `claude`, reads and writes JSON lines
```

1. **Finding Claude Code.** The app runs the user's login shell once and
   records its environment (the same PATH a Terminal window gets), then looks
   up `claude` on that PATH. Variables a parent Claude Code session leaves in
   the app's environment (`CLAUDECODE`, `CLAUDE_CODE_*`) are removed first:
   they make a child `claude` wait for its parent to refresh the login.
2. **Starting a session.** On the first message, the app starts:

   ```
   claude -p --input-format stream-json --output-format stream-json --verbose
          --include-partial-messages --permission-prompt-tool stdio
          --permission-mode default --append-system-prompt <document role>
          --disallowedTools <tools that need UI the chat doesn't have>
          [--resume <session id>]
   ```

   in the folder open in the sidebar (else the document's folder), the same
   rule as the terminal. This is the route Anthropic documents for driving
   Claude Code from another language; VS Code's panel uses the same flags.
3. **Messages.** Each line on stdout is one JSON message: `system/init`,
   `stream_event` (text as it is written), `assistant` (finished text and
   tool calls), `user` (tool results), `control_request` (approval needed)
   and `result` (end of a request). The app writes user messages, approval
   answers (`control_response`) and `interrupt` requests to stdin.
4. **Context.** Every user message starts with an `<mdviewer-context>` block:
   the document's path (relative to the session folder), the selected text,
   and a note if the user undid Claude's last change. The system prompt
   explains the block and asks for short replies, without pasting the edited
   text.
5. **Approvals.** `can_use_tool` requests for Read, Edit, MultiEdit or Write
   on the open document are allowed at once. Everything else shows a native
   banner with Allow and Deny. The user's own permission rules still apply
   first, so tools they already allowed never ask.
6. **Undo.** Before each message the app saves unsaved edits, then keeps a
   copy of the document's bytes. When the request ends and the file differs,
   an Undo bar appears. Undo writes the old bytes back; if the file changed
   again since, it asks first.
7. **Session lifetime.** One `claude` process per window, kept alive between
   messages. If it exits, the next message resumes the same session. New
   Chat ends it. Quitting asks first while Claude is working.

## Security

- The transcript web view has no script message handlers, like the document
  previews: page content cannot send messages, approve tools or reach the app.
  Allow, Deny, Undo and the input box are native controls.
- Replies pass through markdown-it and DOMPurify under a strict content
  security policy. Remote images are blocked, so a reply (or a document that
  steers it) can't load a URL that carries data out.
- Only the open document is edited without asking, and that edit can be
  undone. Commands and other files always ask.
- MD Viewer never sees or stores the Claude login; Claude Code handles
  sign-in through Anthropic's own flow.

## Errors

| Case | What the user sees |
| --- | --- |
| `claude` not found | Banner with the install command and the setup guide |
| Not signed in | Banner with **Sign In**, which opens the terminal and runs `claude auth login` |
| API or request error | The error text as a red notice in the transcript |
| `claude` exits unexpectedly | Notice with the last lines it printed; the next message resumes |

## Testing

- Core unit tests (Swift Testing): line splitting (including Hebrew split
  across reads), message decoding, message encoding, tool step wording,
  approval policy, undo checks, the session state machine, environment
  cleanup and executable lookup, and the process wrapper against a fake
  `claude` script.
- Web tests (Node + jsdom): the transcript page renders each item kind,
  right-to-left text, streaming updates, and drops scripts and remote images.
- In the app, through the automation hook: a real edit with Undo, a denied
  command, Stop, and the not-signed-in notice.
