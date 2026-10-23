import AppKit

// A plain AppKit app: no storyboards or nibs, everything is built in code.
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular) // a Dock icon and menus even when run from source, outside the app bundle
app.run()
