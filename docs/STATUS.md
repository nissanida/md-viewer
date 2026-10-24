# Status

**As of 2026-10-24:** all features in the brief are built. Version 0.1.0 is
installed in `/Applications`, and `mdviewer` is linked into `/opt/homebrew/bin`.
Publishing to GitHub is prepared but paused, with nothing pushed (owner's
call): see [Publishing to GitHub](#publishing-to-github).

The [document chat](#document-chat) is merged into `main`, tested live with
real Claude, and installed.

## Document chat

A chat panel on the right (⌃⌘C, or the Claude button in the toolbar) for
changing the open document in plain words. Design: `docs/CHAT_DESIGN.md`;
decisions D-012 to D-016.

| Area | How | Result |
| --- | --- | --- |
| Claude Code's message format, launch arguments, the transcript, step wording, approvals, the context sent with each message, model / effort / Auto choices | 60 Swift tests, with real output from Claude Code 2.1.158 where it matters | Pass |
| Finding `claude` through the login shell, dropping a parent session's variables, running the process | 10 Swift tests, including a stand-in `claude` script and writing after it exited | Pass |
| The transcript page: each item kind, right to left text, streaming, sanitizing, no remote images, staying on the newest message | 10 Node tests | Pass |
| The panel in the app | A test copy driven through the automation hook with `scripts/fake-claude.py` | Edit applied without asking; Undo restored the file byte for byte and Claude was told; Allow and Deny; Stop; the not-signed-in notice; selected text sent and shown; dark mode; a new model, effort or Auto mode restarts Claude Code with the right options at the next message |
| Live, with real Claude (signed in, Pro plan, mostly Haiku) | The same test copy, driven the same way | Claude read and edited the document (no approval asked) and replied in one sentence; a command asked Allow/Deny and nothing ran after Deny; Stop ended a long reply; switching Haiku to Default with Low effort and Auto on resumed the same conversation (it remembered a word) |

**Not tested yet:**
- **Real key presses** in the message box (Return sends, Shift+Return adds a
  line). Messages were sent through the automation hook.
- **The toolbar symbol's color in the front window.** Snapshots of the
  background window show it gray, like the other toolbar icons; the header
  shows it orange.

**Known limitations:** chats aren't kept after quitting; there is one chat per
window, working in the folder where it started; long tool steps are cut short
to one line; a new model, effort or mode applies from the next message (Claude
Code restarts in the same conversation, which takes a second or two).

## What was tested, and how

| Area | How | Result |
| --- | --- | --- |
| Markdown rendering: tables, task lists, code highlighting, footnotes, alerts, front matter, heading ids, Hebrew direction | 14 Node tests on the shipped `render.js` and libraries, plus snapshots of the real app | Pass |
| Sanitizing: script, event handlers, `javascript:` links, iframe, style, form, object | Node tests | Pass |
| File watching: in-place edit, atomic replace (how Claude Code saves), subfolders, deletion, stop | 5 Swift tests on real files with FSEvents | Pass |
| Reload decisions, link routing, folder listing, `claude` lookup through the login shell, file types to claim as default, folder trust rules | 24 Swift tests | Pass |
| Live reload in the app | Edited the open file both ways while the app ran | Preview updated, scroll position kept |
| Unsaved edits vs. a change on disk | Typed, changed the file, chose each option | Both "Keep My Edits" + Save and "Use Version on Disk" behave correctly |
| Terminal | Opened the panel; read the screen, the process tree and snapshots | Login shell in the open folder; `claude` started from the button and its interface rendered in full color (diffs, syntax colors); the button greys out while it runs; nothing left running after quitting |
| HTML | Opened a page with a script, CDN script, remote image and local CSS | Untrusted: local CSS only. Trusted: script and CDN ran. Revoking restores the block |
| Trust Folder | Trusted the sidebar folder from the notice and from the menu; opened a file in another subfolder; stopped trusting | Both files ran scripts once trusted; stopping blocked them again |
| Links, find, PDF, sidebar refresh, session restore, empty state | Driven through the automation hook, checked by snapshot | Work |
| Menus and shortcuts | Dumped the live menu bar | Every shortcut is mapped to the right action |
| Default app | Asked macOS which apps it offers per file type; checked the new menu items and the one-time offer | Offered for .md, .markdown, .mdx and HTML; Chrome stays the HTML default. The offer appears on the second launch and never again after No Thanks |
| Size and speed | `footprint`, launch timing | 7.7 MB app, 27 MB footprint, window in about 0.5 s |

## Not tested

- **Real key presses and mouse drags.** The app was never brought to the front
  while you were working, so shortcuts were checked as menu mappings, not
  typed. Dropping files on the window or Dock icon uses the same code path as
  Finder's Open, which was tested.
- **Enabled states of window menu items while another app is in front.** The
  app was kept in the background, so items like **Trust “folder”…** were
  checked through their actions, not by opening the menu.
- **Pressing Make Default.** It changes your Mac's default apps, so that click
  was left to you; the menu items and the offer were checked up to that point.
- **The "Claude Code isn't installed" notice.** Claude Code is installed on
  this Mac, and even a shell without your profile finds it (Homebrew is on the
  system PATH). The lookup returning "not found" is unit-tested.
- **The Intel build on an Intel Mac.** The universal binary was built and
  verified, but not run on Intel hardware.

## Known limitations

- HTML edits show in the preview after saving, not while typing (markdown
  previews live).
- To stay fast, the sidebar stops looking inside a folder after about 800
  items, so a large folder can appear in the list even if it holds no documents.
- After each rebuild, macOS may ask again for permission to read Desktop,
  Documents or iCloud Drive (an ad-hoc signed app gets a new identity per
  build).

## Publishing to GitHub

Prepared on 2026-10-24, then paused before anything was pushed (owner's
call). There is no remote yet. The owner's choices: public, named
`md-viewer`, MIT license, and both a download and build steps (D-017).

**Done, committed here:**
- `LICENSE` (MIT, Daniel Nissani).
- New commits here use GitHub's no-reply address instead of the personal
  email (set in this repository's `.git/config`).
- The Claude symbol stays in this folder only (D-014): it is listed in
  `.gitignore` and no longer tracked.
- The tests no longer use a personal name as a folder name.
- README install steps for both ways, and `make zip` for the download.
  Tested: universal, 3.1 MB, signature valid after unzipping, no Claude symbol.
- The app no longer carries the Mac's user name. Release builds held it in
  the folder paths of their debug info and in one source path (`#filePath`);
  `build-app.sh` now strips the debug info (function names stay, for crash
  reports), the source path is debug-only, and `make zip` stops if the app
  contains a path from the Mac that built it.
- Every commit and file version was searched for personal data and secrets:
  only the known email and the Claude symbol were found.

**Left, when the owner says go:**
1. Rewrite the six older commits, which still carry the personal email and
   the Claude symbol: swap in the no-reply address and drop the symbol file,
   keeping messages, dates and code. It needs the owner's explicit yes,
   because Claude Code's safety check blocks history rewrites. Tried on a
   copy (2026-10-24): same commits, code, dates and messages; only no-reply
   emails; no symbol anywhere. The symbol stayed in the folder, but back up
   `web/claude-symbol.svg` first anyway.
2. `gh repo create md-viewer --public --source . --remote origin --push`.
3. `make zip`, then publish the zip as release v0.1.0 (steps below).
4. Check the repository page, and add the URL and date to the log.

**To publish a new version:**
1. Raise `VERSION` in the `Makefile`, run `make test`, then commit and push.
2. Run `make zip`. It builds `MD-Viewer-<version>.zip` from the committed code
   and prints its SHA-256.
3. Publish it: `gh release create v<version> <zip> --target <commit> --title
   "MD Viewer <version>" --notes-file <notes>`. Copy the previous release's
   notes (install steps) and put in the new SHA-256.
4. Run `make install` to update the app on this Mac.

Good to know: the folder is in iCloud Drive, so the GitHub copy also serves as
the backup. Build products and caches live in `~/Library/Caches/md_html_reader`
and never enter git.

## Ideas, not started

Mermaid diagrams and math, scroll sync between editor and preview, markdown
syntax colors in the editor, tabs or multiple windows.

## Log

- **2026-10-24:** before publishing, found the Mac's user name inside the app
  (build folders in its debug info, one source path) and removed it from
  release builds; `make zip` now refuses a build that has it. Tried the
  history rewrite on a copy. Still waiting for the owner's go.
- **2026-10-24:** prepared publishing on GitHub (license, install steps for a
  download and for building, `make zip`, the Claude symbol out of git, a
  neutral test folder name); paused before the history rewrite and the first
  push (owner's call).
- **2026-10-23:** built the document chat on `feature/document-chat`: a chat
  panel that runs Claude Code in its message mode, edits the open document
  with Undo, asks before anything else, and uses the Claude symbol (owner's
  request). Tested with a stand-in; the live test waits for signing in.
- **2026-10-23:** added model, effort and Auto mode under the chat's message
  box (owner's request), fixed the transcript not following new messages when
  a notice opened under it, tested live with real Claude, and installed the
  chat build in `/Applications`.
- **2026-10-23:** merged the document chat (`feature/document-chat`) into
  `main`.
- **2026-10-23:** restyled the model and effort choices as pill buttons named
  for the model behind them, and in Auto mode moved Undo to a small button in
  the chat's header (both at the owner's request); reinstalled.
- **2026-10-23:** committed everything locally (`main`), and logged the steps
  to publish on GitHub in a new session.
- **2026-10-23:** the terminal now starts in the open folder (project root),
  not the file's subfolder.
- **2026-10-23:** added Trust Folder for HTML (the sidebar's folder) and
  View → Trusted Folders.
- **2026-10-23:** added Make Default for Markdown / HTML Files to the app menu,
  and a one-time offer from the second launch.
- **2026-10-23:** built v0.1.0 from the brief: native viewer, terminal with
  Claude Code, HTML trust, extras, tests, README, installed.
