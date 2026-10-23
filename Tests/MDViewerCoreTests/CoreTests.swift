import Foundation
import Testing
@testable import MDViewerCore

struct DocumentKindTests {
    @Test(arguments: ["a.md", "b.MARKDOWN", "c.mdx", "d.mdown"])
    func recognizesMarkdown(_ name: String) {
        #expect(DocumentKind(url: URL(fileURLWithPath: "/tmp/\(name)")) == .markdown)
    }

    @Test(arguments: ["a.html", "b.HTM", "c.xhtml"])
    func recognizesHTML(_ name: String) {
        #expect(DocumentKind(url: URL(fileURLWithPath: "/tmp/\(name)")) == .html)
    }

    @Test func ignoresOtherFiles() {
        #expect(DocumentKind(url: URL(fileURLWithPath: "/tmp/a.txt")) == nil)
    }

    @Test func listsTheSystemFileTypesToClaimAsDefault() {
        let html = DocumentKind.html.fileTypes.map(\.identifier)
        #expect(html.contains("public.html"))
        for type in DocumentKind.markdown.fileTypes + DocumentKind.html.fileTypes {
            #expect(!type.isDynamic) // a made-up type can't have a default app
        }
        #expect(Set(html).count == html.count)
    }
}

struct LinkRouterTests {
    @Test func opensLocalDocumentsInTheApp() {
        let url = URL(string: "mdv-file://local/Users/me/My%20Notes/%D7%A9%D7%9C%D7%95%D7%9D.md#setup")!
        #expect(LinkRouter.action(for: url) == .openDocument(URL(fileURLWithPath: "/Users/me/My Notes/שלום.md"), fragment: "setup"))
    }

    @Test func opensOtherLocalFilesWithTheirDefaultApp() {
        let url = URL(string: "mdv-file://local/Users/me/report.pdf")!
        #expect(LinkRouter.action(for: url) == .openFile(URL(fileURLWithPath: "/Users/me/report.pdf")))
    }

    @Test func opensWebLinksExternally() {
        let url = URL(string: "https://example.com/a?b=c")!
        #expect(LinkRouter.action(for: url) == .openExternal(url))
    }

    @Test func ignoresScriptsAndUnknownSchemes() {
        #expect(LinkRouter.action(for: URL(string: "javascript:alert(1)")!) == .ignore)
        #expect(LinkRouter.action(for: URL(string: "data:text/html,hi")!) == .ignore)
    }

    @Test func roundTripsLocalFileURLs() {
        let file = URL(fileURLWithPath: "/Users/me/מסמכים/a b.png")
        #expect(LocalFileURL.fileURL(from: LocalFileURL.make(for: file)) == file)
    }
}

struct FolderScannerTests {
    @Test func listsDocumentsAndFoldersThatHoldThem() throws {
        let folder = try TemporaryFolder()
        try folder.write("", to: "b.md")
        try folder.write("", to: "A.html")
        try folder.write("", to: "notes.txt")
        try folder.write("", to: "docs/guide.md")
        try folder.write("", to: "empty/readme.txt")
        try folder.write("", to: "node_modules/pkg/README.md")
        try folder.write("", to: ".hidden/x.md")

        let names = FolderScanner.entries(in: folder.url).map(\.name)
        #expect(names == ["docs", "A.html", "b.md"])
    }
}

struct ShellEnvironmentTests {
    @Test func parsesProbeOutputSurroundedByShellNoise() {
        let marker = ShellEnvironment.probeMarker
        let output = "Last login: today\nwelcome!\n\n\(marker)\n/opt/homebrew/bin/claude\n\n\(marker)\n"
        #expect(ShellEnvironment.parseProbeOutput(output) == "/opt/homebrew/bin/claude")
    }

    @Test func reportsMissingCommands() {
        let marker = ShellEnvironment.probeMarker
        #expect(ShellEnvironment.parseProbeOutput("\n\(marker)\n\n\(marker)\n") == nil)
        #expect(ShellEnvironment.parseProbeOutput("zsh: something failed") == nil)
    }

    @Test func terminalEnvironmentIsUTF8AndDropsNestedSessionMarkers() {
        let env = ShellEnvironment.terminalEnvironment(from: ["PATH": "/usr/bin", "CLAUDECODE": "1", "HOME": "/Users/me"])
        #expect(env.contains("TERM=xterm-256color"))
        #expect(env.contains("LANG=en_US.UTF-8"))
        #expect(!env.contains { $0.hasPrefix("CLAUDECODE=") })
        #expect(env.contains("HOME=/Users/me"))
    }

    @Test func resolvesCommandsThroughTheLoginShell() async {
        // `ls` exists on every Mac, wherever the user's PATH points.
        let resolved = await ShellEnvironment.resolveCommand("ls")
        #expect(resolved?.hasSuffix("/ls") == true)
        #expect(await ShellEnvironment.resolveCommand("surely-not-a-real-command-mdv") == nil)
    }
}

struct HTMLContentScanTests {
    @Test func detectsScripts() {
        #expect(HTMLContentScan(html: "<p onclick=\"x()\">a</p>").hasScripts)
        #expect(HTMLContentScan(html: "<script src=app.js></script>").hasScripts)
        #expect(!HTMLContentScan(html: "<p>Only text about scripts.</p>").hasScripts)
    }

    @Test func detectsRemoteResourcesButNotPlainLinks() {
        #expect(HTMLContentScan(html: "<img src=\"https://x.com/a.png\">").hasRemoteResources)
        #expect(HTMLContentScan(html: "<link rel=stylesheet href='//cdn.x.com/a.css'>").hasRemoteResources)
        #expect(HTMLContentScan(html: "<div style=\"background:url(https://x.com/a.png)\"></div>").hasRemoteResources)
        #expect(!HTMLContentScan(html: "<a href=\"https://x.com\">site</a><img src=\"local.png\">").hasRemoteResources)
    }
}

struct TrustListTests {
    @Test func trustsEverythingInsideATrustedFolder() {
        let trust = TrustList(folders: ["/Users/me/project"])
        #expect(trust.isTrusted(file: "/Users/me/project/report.html"))
        #expect(trust.isTrusted(file: "/Users/me/project/out/deep/chart.html"))
        #expect(!trust.isTrusted(file: "/Users/me/other/report.html"))
    }

    @Test func doesNotTrustSiblingFoldersThatShareANamePrefix() {
        let trust = TrustList(folders: ["/Users/me/project"])
        #expect(!trust.isTrusted(file: "/Users/me/project2/report.html"))
        #expect(!trust.isTrusted(file: "/Users/me/project.html"))
    }

    @Test func trustsSingleFiles() {
        let trust = TrustList(files: ["/Users/me/a.html"])
        #expect(trust.isTrusted(file: "/Users/me/a.html"))
        #expect(!trust.isTrusted(file: "/Users/me/b.html"))
    }

    @Test func namesTheInnermostTrustingFolder() {
        let trust = TrustList(folders: ["/Users/me", "/Users/me/project"])
        #expect(trust.folder(trusting: "/Users/me/project/a.html") == "/Users/me/project")
        #expect(trust.covers(folder: "/Users/me/project/docs"))
        #expect(!TrustList(folders: ["/Users/me/project"]).covers(folder: "/Users/me"))
    }
}
