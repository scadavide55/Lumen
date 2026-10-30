import AppKit

/// A saved list of steps that Tacet runs in order, the same way every time: "open my work setup", "copy title, link
/// and selection as Markdown". No AI and no key needed. Run one from the command bar, Tab › Automations, or its
/// shortcut (⌃⌥⌘1 to ⌃⌥⌘9).
struct Automation: Codable, Identifiable, Equatable {
    enum Step: Codable, Equatable, Hashable {
        case openTab(URL)
        case openHere(URL)
        case openSpace(UUID)
        case openSplit(URL)
        case copyMarkdown
        case groupSelectedLinks
        case closeOtherTabs
        case hibernateOthers
        case reader
        case focusMode
        case appearance(String)

        /// What the step does, for the editor.
        var label: String {
            switch self {
            case .openTab(let u): String(format: L("Open %@ in a new tab"), InputResolver.displayHost(u))
            case .openHere(let u): String(format: L("Open %@ in this tab"), InputResolver.displayHost(u))
            case .openSpace(let id): String(format: L("Switch to the %@ Space"), Spaces.shared.space(id)?.name ?? "?")
            case .openSplit(let u): String(format: L("Show %@ beside this page"), InputResolver.displayHost(u))
            case .copyMarkdown: L("Copy title, link and selection as Markdown")
            case .groupSelectedLinks: L("Open the selected links in a new group")
            case .closeOtherTabs: L("Close the other tabs")
            case .hibernateOthers: L("Put the other tabs to sleep")
            case .reader: L("Show the page in Reader")
            case .focusMode: L("Turn Focus Mode on or off")
            case .appearance(let a): a == "dark" ? L("Dark appearance") : a == "light" ? L("Light appearance") : L("System appearance")
            }
        }
    }

    var id = UUID()
    var name: String
    var steps: [Step] = []
    /// 1 to 9 for ⌃⌥⌘1 to ⌃⌥⌘9.
    var shortcut: Int?

    var shortcutLabel: String? { shortcut.map { "⌃⌥⌘\($0)" } }

    /// Ready-made ones, shown in the editor to start from.
    static var examples: [Automation] {
        [
            Automation(name: L("Copy as Markdown note"), steps: [.copyMarkdown]),
            Automation(name: L("Collect selected links"), steps: [.groupSelectedLinks]),
            Automation(name: L("Just this page"), steps: [.closeOtherTabs, .focusMode]),
            Automation(name: L("Clear the decks"), steps: [.hibernateOthers, .reader]),
        ]
    }
}

enum AutomationRunner {
    /// Runs the steps one after another in the window, waiting for pages where a later step needs them.
    @MainActor
    static func run(_ a: Automation, in b: BrowserState) async {
        for step in a.steps {
            switch step {
            case .openTab(let u):
                b.newTab(url: u)
            case .openHere(let u):
                if let t = b.current { t.load(u) } else { b.newTab(url: u) }
            case .openSpace(let id):
                b.switchSpace(to: id)
            case .openSplit(let u):
                let t = b.newTab(url: u, select: false, after: b.current)
                b.openSplit(t)
            case .copyMarkdown:
                await copyMarkdown(from: b.current)
            case .groupSelectedLinks:
                await groupSelectedLinks(in: b)
            case .closeOtherTabs:
                if let t = b.current { b.closeOthers(t) }
            case .hibernateOthers:
                b.hibernateOthers()
            case .reader:
                if let t = b.current, !t.isReader { await withCheckedContinuation { done in t.toggleReader { _ in done.resume() } } }
            case .focusMode:
                b.focusMode.toggle()
            case .appearance(let a):
                Settings.shared.theme = a == "dark" ? .dark : a == "light" ? .light : .system
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// "> selection" (when there is one), then "[Title](address)".
    @MainActor
    private static func copyMarkdown(from tab: Tab?) async {
        guard let tab, let url = tab.url else { return }
        let selection = (try? await tab.webView?.evaluateJavaScript("String(window.getSelection ? window.getSelection() : '')")) as? String ?? ""
        let title = tab.title.replacingOccurrences(of: "]", with: "\\]")
        let link = "[\(title)](\((URLCleaner.clean(url) ?? url).absoluteString))"
        let quote = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = quote.isEmpty ? link : quote.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n" + link
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Every link inside the selection opens as a tab, together in a group named after the page.
    @MainActor
    private static func groupSelectedLinks(in b: BrowserState) async {
        guard let tab = b.current, let wv = tab.webView else { return }
        let js = """
        const s = getSelection(); if (!s || !s.rangeCount) return [];
        const r = s.getRangeAt(0), root = r.commonAncestorContainer.nodeType === 1 ? r.commonAncestorContainer : r.commonAncestorContainer.parentElement;
        const links = [...root.querySelectorAll('a[href]')].filter(a => r.intersectsNode(a)).map(a => a.href).filter(h => /^https?:/.test(h));
        const own = root.closest && root.closest('a[href]'); if (own) links.push(own.href);
        return [...new Set(links)].slice(0, 30);
        """
        let found = ((try? await wv.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .defaultClient)) as? [String] ?? [])
            .compactMap(URL.init(string:))
        guard !found.isEmpty else { return }
        let opened = found.map { u -> Tab in
            let t = b.newTab(url: u, select: false, after: b.tabs.last)
            return t
        }
        _ = b.group(opened, named: tab.title.isEmpty ? L("Links") : String(tab.title.prefix(30)))
    }
}
