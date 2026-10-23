# Decisions

Each entry: what was decided, why, and what else was considered. Newest last.

## D-001 Native Swift app (AppKit), not Electron or Tauri — 2026-10-23

The app is native Swift with AppKit, using WebKit for previews and SwiftTerm
for the terminal.

- **Why:** the brief puts a calm, fast, low-memory app first. The result is a
  7.7 MB universal app with a 27 MB memory footprint, and its window appears
  about 0.5 s after launch. File types, Open With, Dock drops and dark mode
  are native. It builds with only the Command Line Tools: no Xcode, no Rust,
  no npm at build time.
- **Considered:** Electron with xterm.js and node-pty is the most familiar
  stack, but costs about 200 MB of disk and over 150 MB of memory. Tauri is
  small, but needs a Rust toolchain (not installed here), takes minutes to
  build, and puts the terminal and the documents in the same web view.

## D-002 Markdown is rendered in JavaScript inside WebKit — 2026-10-23

markdown-it (with footnotes, plus small built-in plugins for task lists, GitHub
alerts, heading ids and front matter), highlight.js and DOMPurify run in the
preview page.

- **Why:** this is the best-tested route to GitHub-flavored markdown with safe
  inline HTML. DOMPurify needs a real DOM, so the sanitizing has to happen in
  the page anyway.
- **Considered:** cmark-gfm in Swift. It is fast, but it drops all inline
  HTML, which READMEs use often (`<details>`, `<img width>`).

## D-003 Security by separation — 2026-10-23

- The preview pages have no script-message handlers: they cannot call the
  app. Links are decided by the native navigation policy.
- Markdown passes through DOMPurify, and a content security policy allows only
  the app's own scripts.
- The terminal is a native view with no connection to any web view.
- HTML files load with scripts off and a WebKit content blocker for all
  network requests, until the user trusts the file. Trust is remembered per
  file path.
- Links to local files that could run (apps, scripts, installers) are shown in
  Finder instead of opened.

## D-004 SwiftTerm for the terminal — 2026-10-23

A native terminal emulator (MIT) with a real pseudo-terminal, true color,
bracketed paste, the kitty keyboard protocol and OSC 10/11 color reports.
Because of the color reports, Claude Code's "auto" theme can follow the
panel's light or dark background. Pinned to 1.20.0, the last release before
the 2.0 previews.

## D-005 The terminal starts a login shell — 2026-10-23

Apps opened from Finder get a bare PATH. Starting the user's shell as a login
shell loads their profile the same way Terminal.app does, so `claude` and Node
tools resolve identically. The app strips `CLAUDECODE`, which would otherwise
make Claude Code refuse to start as a "nested" session.

## D-006 The terminal starts in the open folder — 2026-10-23

The shell starts in the folder open in the sidebar, usually the project root,
so Claude Code finds the project's `CLAUDE.md` and git root even when the open
file sits in a subfolder (`docs/guide.md`). A file opened on its own makes its
folder the open folder, so then the two are the same. This is the owner's call:
the brief said "the folder of the file", and the owner chose the project root
for files in subfolders. A running session stays where it started; Terminal →
New Shell in Open Folder moves it.

## D-007 Build products stay outside iCloud Drive — 2026-10-23

The project lives in iCloud Drive. Build folders, the built app and test
dependencies go to `~/Library/Caches/md_html_reader`. iCloud would otherwise
sync thousands of files, and the metadata it adds makes `codesign` fail.

## D-008 JavaScript libraries are committed, not installed — 2026-10-23

The prebuilt browser files are pinned in `scripts/update-vendor.sh` and
committed in `web/vendor/`. Building the app needs no Node; only the
rendering tests use Node (with jsdom, installed into the cache folder).

## D-009 Remote images are allowed in markdown, blocked in HTML — 2026-10-23

Markdown may show `https` images (badges, diagrams), as GitHub and VS Code
do. Scripts never run, so nothing can read a page's content and send it away.
HTML files block all remote requests until trusted, as the brief asks.

## D-010 Becoming the default app from inside the app — 2026-10-23

The MD Viewer menu has **Make Default for Markdown Files** and **Make Default
for HTML Files** (`NSWorkspace.setDefaultApplication`). They cover every file
type this Mac uses for those extensions, including other apps' types such as
Typora's for `.mdx`. The HTML item first explains what changes, because local
HTML files will no longer open in the browser.

From the second launch, a one-time banner offers to make MD Viewer the
markdown default. It never returns once answered. The first launch stays free
of prompts, as the brief asks. The offer covers markdown only: HTML stays a
deliberate menu choice (owner's call), because it takes HTML files away from
the browser.

## D-011 Trusting a whole folder of HTML files — 2026-10-23

**Trust Folder…** in the HTML notice trusts the folder open in the sidebar,
with its subfolders. This was the owner's choice over trusting only the
file's own folder. It removes the click-per-file friction for project
reports, which matters if MD Viewer becomes the HTML default. The user
confirms first, with a stronger warning for broad folders (home, Downloads,
Desktop, Documents, iCloud Drive). Trusted folders are listed, and can be
removed, under **View → Trusted Folders**. The matching rule (`TrustList`)
is unit-tested so that `/a/project` never trusts `/a/project2`.

## D-012 The chat runs Claude Code in its message mode — 2026-10-23

The chat panel starts the user's own `claude` with `-p --input-format
stream-json --output-format stream-json` and talks to it in JSON lines, with
approvals over the same channel (`--permission-prompt-tool stdio`). See
`docs/CHAT_DESIGN.md`.

- **Why:** it is Claude Code itself, with the user's account, settings, skills
  and CLAUDE.md, and it is the route Anthropic documents for driving Claude
  Code from another language. VS Code's Claude panel uses the same flags. It
  needs nothing new to build or run, in keeping with D-001 and D-008.
- **Considered:** the Agent SDK in a Node helper (an official API, but it adds
  Node and its own copy of Claude Code); the Claude API directly (needs an API
  key and loses Claude Code's tools and settings); only the terminal (which
  reads as a code tool, the reason for this work).
- **Scope (owner's call):** a chat about the open document, not a code editor:
  no file pickers, slash commands, model picker or diff views. The terminal
  stays as it was.

## D-013 Edits to the open document apply at once, with Undo — 2026-10-23

Claude's requests to read or edit the open document are allowed without
asking. Everything else (other files, commands, the web) asks Allow or Deny in
a native banner, after the user's own permission rules. Before each message
the app saves unsaved edits and keeps a copy of the document; Undo writes it
back and tells Claude in the next message.

- **Why:** changing the file easily is the point of the chat (owner). A change
  the user sees and can undo needs no approval; anything beyond the document
  does.
- **Security:** the transcript page has no script message handlers (D-003), so
  a reply can't approve anything or reach the app: Allow, Deny, Undo and the
  message box are native. Replies are sanitized like documents, and remote
  images are blocked, so a reply (or a document that steers it) can't carry
  data out in an image URL.

## D-014 The chat's symbol is the Claude symbol — 2026-10-23

The toolbar button and the chat header show the Claude symbol
(`web/claude-symbol.svg`, the artwork from Anthropic's VS Code extension), in
Claude's orange. Owner's call. It is Anthropic's trademark: fine in the
owner's own copy, but Anthropic's terms require written permission to use it
in a published app. Before publishing, ask Anthropic or replace that one file
with a neutral icon (without the file, the app falls back to a sparkle).

## D-015 Child processes don't inherit a parent Claude Code session — 2026-10-23

Launched from a Claude Code session (while developing it), the app inherits
`CLAUDECODE` and `CLAUDE_CODE_*` variables, which make a child `claude` refuse
to start or wait for its parent to refresh the login. The terminal and the
chat now drop every `CLAUDE*` variable the app inherited; settings the user
exports in their shell profile come back through the login shell. This
extends D-005.
