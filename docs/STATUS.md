# Status

**As of 2026-10-23:** all features in the brief are built. Version 0.1.0 is
installed in `/Applications`, and `mdviewer` is linked into `/opt/homebrew/bin`.

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

## Ideas, not started

Mermaid diagrams and math, scroll sync between editor and preview, markdown
syntax colors in the editor, tabs or multiple windows.

## Log

- **2026-10-23:** the terminal now starts in the open folder (project root),
  not the file's subfolder.
- **2026-10-23:** added Trust Folder for HTML (the sidebar's folder) and
  View → Trusted Folders.
- **2026-10-23:** added Make Default for Markdown / HTML Files to the app menu,
  and a one-time offer from the second launch.
- **2026-10-23:** built v0.1.0 from the brief: native viewer, terminal with
  Claude Code, HTML trust, extras, tests, README, installed.
