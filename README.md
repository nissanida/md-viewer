# MD Viewer

A calm macOS app for reading and lightly editing markdown, viewing HTML, and
running Claude Code next to the document. Native (Swift + AppKit), about 8 MB,
starts in half a second, and free and open source all the way down.

## Install

You need the Xcode Command Line Tools (`xcode-select --install`). Then:

```bash
make install
```

This builds the app for Apple Silicon and Intel, copies it to
`/Applications/MD Viewer.app` and registers it with Finder. Run the same
command again after any change to rebuild and reinstall. To drag the app into
Applications yourself instead, run `make app && make reveal`.

Optional command-line helper (`mdviewer README.md`, `mdviewer docs/`, or just
`mdviewer` for the current folder):

```bash
make install-cli
```

`make uninstall` removes both.

### Make it the default for markdown (or HTML)

In the app, open the **MD Viewer** menu and choose **Make Default for Markdown
Files** (or **Make Default for HTML Files**). Once it is the default, the item
shows a checkmark. From the second launch on, the app also offers this once, in
a slim banner above a markdown document.

The Finder way works too: select a `.md` file, press ⌘I (Get Info), choose
**MD Viewer** under **Open with**, and click **Change All…**. Use the same steps
with another app to switch back. As HTML default, MD Viewer opens local HTML
files (with scripts off until trusted); web links still open in your browser.

### Opening the app on another Mac

The app is signed ad hoc, not by a registered Apple developer. An app you build
yourself runs without warnings. If you copy it to another Mac, macOS blocks
the first launch. On macOS 15 and later the old right-click → **Open** trick
no longer works:

1. Try to open the app once, and dismiss the warning.
2. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** next to MD Viewer.

Or, in Terminal: `xattr -dr com.apple.quarantine "/Applications/MD Viewer.app"`.
See [Notarization](#notarization-later) to remove the warning for good.

## Using it

Open a file from Finder, the Dock icon, ⌘O, or by dropping it on the window.
Open a folder (⇧⌘O, or drop it) to browse its markdown and HTML files in the
sidebar; its README opens automatically. Everything else stays hidden until
you ask for it.

| Action | Shortcut |
| --- | --- |
| Open file / folder | ⌘O / ⇧⌘O |
| Preview / Source / Edit with live preview | ⌘1 / ⌘2 / ⌘3 |
| Toggle source view | ⌘/ |
| Save | ⌘S |
| Find, next, previous | ⌘F, ⌘G, ⇧⌘G |
| Sidebar / Outline / Terminal | ⌃⌘S / ⌃⌘O / ⌃` |
| Start Claude Code | ⌃⇧` |
| Send file path / selection to the terminal | ⌥⌘P / ⌥⌘J |
| Zoom in / out / actual size | ⌘= / ⌘- / ⌘0 |
| Reload from disk | ⌘R |
| Print / Export as PDF | ⌘P / File menu |

- **Live reload.** When a file changes on disk (for example, Claude Code edits
  it), the preview updates and keeps your place. If you have unsaved edits,
  the app asks before replacing them.
- **Links.** Links to other markdown or HTML files open in the app, web links
  in your browser. Links to other local files open only if they are plain
  documents (images, PDFs, text); anything that could run, such as apps or
  scripts, is shown in Finder instead.
- **Right-to-left text.** Hebrew and Arabic paragraphs, lists and tables read
  right to left automatically.
- **Your place is remembered:** the last folder and file, window size, view
  mode and which panels are open.

### Terminal and Claude Code

The terminal panel (⌃`) runs your own shell as a login shell, so `claude`,
`node` and everything on your PATH are found exactly as in Terminal.app. It
starts in the folder open in the sidebar (usually your project's root, where
`CLAUDE.md` lives). Click **Start Claude Code**, or turn
on **Terminal → Start Claude Code Automatically**. If `claude` isn't
installed, the panel shows how to install it.

- **Shift+Return** inserts a newline in Claude Code; Option works as Meta.
- **⌥⌘P** types `@path/to/file` (Claude Code's file reference) at the prompt;
  **⌥⌘J** pastes the selected text. Neither presses Return for you.
- Closing the window keeps the session running; click the Dock icon to come
  back. Quitting asks first if Claude Code (or anything else) is still running.

### HTML files

HTML opens with its scripts turned off and every request to the internet
blocked. Its own local styles and images still load. A notice tells you what
was blocked and offers two ways to allow it:

- **Trust This File:** scripts and remote content for that file only.
- **Trust Folder…:** every HTML file in the folder open in the sidebar
  (usually your project) and its subfolders, including files added later. You
  confirm first; broad folders such as Downloads or your home folder get an
  extra warning.

Trust is remembered. **Stop Trusting** in the notice, or **View → Trusted
Folders**, takes it back.

## Security model

- Every file is treated as untrusted. Markdown is rendered with markdown-it and
  cleaned with DOMPurify, and a strict content security policy lets only the
  app's own scripts run. Raw HTML in markdown can't run scripts, embed frames
  or submit forms.
- The document web views have no bridge to the app at all; links are handled by
  native code. The terminal is a separate native view. A document therefore
  has no way to run commands or type into the terminal.
- Local images are served only if they are images, audio or video, so a
  document can't pull other files into the page.

## Development

```bash
make run FILE=README.md   # run from source, without installing
make test                 # Swift tests + markdown rendering tests (needs Node)
make app ARCHS=arm64      # faster build, Apple Silicon only
make help                 # every task
```

Build products and caches live in `~/Library/Caches/md_html_reader`, outside
iCloud Drive (iCloud would sync thousands of build files and add metadata that
code signing rejects).

| Path | What it holds |
| --- | --- |
| `Sources/MDViewer/` | The app: window, sidebar, previews, editor, terminal, menus |
| `Sources/MDViewerCore/` | Logic without UI: file watching, folder listing, links, shell lookup |
| `web/` | The preview page: `render.js` (markdown pipeline), `page.js`, `style.css`, `vendor/` libraries |
| `packaging/` | `Info.plist` (file types), app icon, `mdviewer` script |
| `scripts/` | App build, icon, vendoring, and the automation helper |
| `Tests/` | Swift tests (`MDViewerCoreTests`) and rendering tests (`web/`) |

The JavaScript libraries are pinned in `scripts/update-vendor.sh` and committed
as files in `web/vendor/`; `make vendor` re-downloads them after a version bump.

**Automation for testing.** Launched with `MDV_AUTOMATION=1`, the app accepts
commands from `scripts/automate.swift` (window snapshots, menu actions, reading
the terminal), so changes can be checked without clicking. Normal launches
never enable it.

```bash
swiftc scripts/automate.swift -o /tmp/automate
open --env MDV_AUTOMATION=1 -a "/Applications/MD Viewer.app" README.md
/tmp/automate "snapshot /tmp/window.png"
```

## Notarization (later)

To share the app without the first-launch warning, it must be signed with a
Developer ID and notarized by Apple. This needs a paid Apple Developer account
(USD 99 a year); the tools are already in the Command Line Tools.

1. Create a **Developer ID Application** certificate in your Apple Developer
   account and install it in Keychain.
2. Sign with the hardened runtime instead of the ad-hoc signature in
   `scripts/build-app.sh`:
   `codesign --force --deep --options runtime --timestamp --sign "Developer ID Application: Your Name (TEAMID)" "MD Viewer.app"`
3. Zip and notarize: `ditto -c -k --keepParent "MD Viewer.app" app.zip`, then
   `xcrun notarytool submit app.zip --apple-id you@example.com --team-id TEAMID --wait`.
4. Attach the ticket: `xcrun stapler staple "MD Viewer.app"`.

## Credits

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT),
[markdown-it](https://github.com/markdown-it/markdown-it) and its footnote
plugin (MIT), [DOMPurify](https://github.com/cure53/DOMPurify) (Apache-2.0 or
MPL-2.0), [highlight.js](https://highlightjs.org) (BSD-3-Clause). Licenses are
in `web/vendor/licenses/`.
