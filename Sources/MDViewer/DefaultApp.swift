import AppKit
import MDViewerCore

/// Makes MD Viewer the default app for markdown or HTML files from inside the
/// app: the same setting as Finder's Get Info > Open with > Change All.
@MainActor
enum DefaultApp {
    /// Only an app bundle can be a default app (not a build run with `swift run`).
    static var canChange: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Whether every file type of this kind already opens in MD Viewer.
    static func isDefault(for kind: DocumentKind) -> Bool {
        let types = kind.fileTypes
        return !types.isEmpty && types.allSatisfy { type in
            NSWorkspace.shared.urlForApplication(toOpen: type).flatMap { Bundle(url: $0)?.bundleIdentifier }
                == Bundle.main.bundleIdentifier
        }
    }

    static func makeDefault(for kind: DocumentKind) async throws {
        for type in kind.fileTypes {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
        }
    }
}
