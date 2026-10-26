import SwiftUI
import WebKit

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Lumen", id: "main") {
            ContentView(isPrivate: false)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { LumenCommands() }

        WindowGroup("Private Window", id: "private") {
            ContentView(isPrivate: true)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)

        Window("Library", id: "library") {
            LibraryView()
        }
        .defaultSize(width: 820, height: 560)

        SwiftUI.Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Lumen restores its own session, so macOS shouldn't reopen windows on top of it.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        Settings.shared.applyTheme()
        ContentBlocker.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleExtraShortcut(event) ? nil : event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !WindowRegistry.shared.open(urls) { Self.openNewWindow() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Session.shared.saveNow()
        guard Settings.shared.clearOnQuit else { return .terminateNow }
        DataCleaner.clear(range: .all, history: true, cookies: true, cache: true) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opens a browser window from AppKit code, through the File menu's New Window item.
    static func openNewWindow() {
        guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.title == "New Window" } == true })?.submenu,
              let index = file.items.firstIndex(where: { $0.title == "New Window" }) else { return }
        file.performActionForItem(at: index)
    }

    /// Shortcuts that menus can't express: ⌘= next to ⌘+, ⇧⌘] / ⇧⌘[ and ⌥⌘→ / ⌥⌘← to switch tabs.
    private static func handleExtraShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags.contains(.command), let b = WindowRegistry.shared.lastFocused, b.window?.isKeyWindow == true else { return false }
        switch (flags, event.keyCode) {
        case ([.command], 24) where event.charactersIgnoringModifiers == "=":
            b.current?.zoom(1)
        case ([.command, .shift], 30), ([.command, .option], 124):
            b.selectNext(1)
        case ([.command, .shift], 33), ([.command, .option], 123):
            b.selectNext(-1)
        default:
            return false
        }
        return true
    }
}

// MARK: - Menus

struct LumenCommands: Commands {
    @FocusedObject private var b: BrowserState?
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var bookmarks = Bookmarks.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                if let b { b.newTabWithPalette() } else { openWindow(id: "main") }
            }
            .keyboardShortcut("t")
            Button("New Window") { openWindow(id: "main") }.keyboardShortcut("n")
            Button("New Private Window") { openWindow(id: "private") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open Location…") { b?.showPalette() }.keyboardShortcut("l").disabled(b == nil)
            Button("Reopen Closed Tab") { b?.reopenClosed() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(b == nil)
            Divider()
            Button("Close Tab") {
                if let b { b.closeCurrent() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Import Bookmarks…") { library(.bookmarks) }
            Button("Print…") { b?.current?.printPage() }.keyboardShortcut("p").disabled(b == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Link") {
                guard let url = b?.current?.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(b == nil)
            Divider()
            Button("Find…") { b?.showFind() }.keyboardShortcut("f").disabled(b == nil)
            Button("Find Next") { findAgain(backwards: false) }.keyboardShortcut("g").disabled(b == nil)
            Button("Find Previous") { findAgain(backwards: true) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(b == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { b?.sidebarVisible.toggle() }.keyboardShortcut("s").disabled(b == nil)
            Button("Command Bar") { b?.showPalette("") }.keyboardShortcut("k").disabled(b == nil)
            Divider()
            Button("Reader") { b?.current?.toggleReader() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(b == nil)
            Button("Split View") {
                guard let b else { return }
                b.splitTab == nil ? b.splitWithNewTab() : b.closeSplit()
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])
            .disabled(b == nil)
            Divider()
            Button("Zoom In") { b?.current?.zoom(1) }.keyboardShortcut("+").disabled(b == nil)
            Button("Zoom Out") { b?.current?.zoom(-1) }.keyboardShortcut("-").disabled(b == nil)
            Button("Actual Size") { b?.current?.zoom(0) }.keyboardShortcut("0").disabled(b == nil)
            Divider()
            Button("Reload Page") { b?.current?.reload() }.keyboardShortcut("r").disabled(b == nil)
            Button("Reload Ignoring Cache") { b?.current?.hardReload() }.keyboardShortcut("r", modifiers: [.command, .option]).disabled(b == nil)
            Button("Stop Loading") { b?.current?.stop() }.keyboardShortcut(".").disabled(b == nil)
            Divider()
        }

        CommandMenu("History") {
            Button("Back") { b?.current?.goBack() }.keyboardShortcut("[").disabled(b == nil)
            Button("Forward") { b?.current?.goForward() }.keyboardShortcut("]").disabled(b == nil)
            Divider()
            Button("Show All History") { library(.history) }.keyboardShortcut("y")
            Menu("Clear History") {
                Button("Last Hour") { History.shared.clear(since: Date().addingTimeInterval(-3600)) }
                Button("Today") { History.shared.clear(since: Calendar.current.startOfDay(for: Date())) }
                Button("All History") { History.shared.clear() }
            }
        }

        CommandMenu("Bookmarks") {
            Button("Bookmark This Page") {
                guard let t = b?.current else { return }
                bookmarks.toggle(url: t.url, title: t.title)
            }
            .keyboardShortcut("d")
            .disabled(b == nil)
            Button("Show Bookmarks") { library(.bookmarks) }.keyboardShortcut("b", modifiers: [.command, .option])
            if !bookmarks.items.isEmpty { Divider() }
            ForEach(bookmarks.items.prefix(30)) { bm in
                Button(bm.title) {
                    if let b { b.newTab(url: bm.url) } else if !WindowRegistry.shared.open([bm.url]) { openWindow(id: "main") }
                }
            }
        }

        CommandMenu("Tab") {
            Button("Next Tab") { b?.selectNext(1) }.keyboardShortcut(.tab, modifiers: .control).disabled(b == nil)
            Button("Previous Tab") { b?.selectNext(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(b == nil)
            Divider()
            Button("Pin or Unpin Tab") { if let b, let t = b.current { b.togglePin(t) } }.disabled(b == nil)
            Button("Duplicate Tab") { if let b, let t = b.current { b.duplicate(t) } }.disabled(b == nil)
            Button("Mute or Unmute Tab") { if let t = b?.current { t.setMuted(!t.isMuted) } }
                .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(b == nil)
            Button("Hibernate Other Tabs") { b?.hibernateOthers() }.disabled(b == nil)
            Divider()
            ForEach(1...9, id: \.self) { i in
                Button(i == 9 ? "Last Tab" : "Tab \(i)") { b?.select(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i))))
                    .disabled(b == nil)
            }
        }

        CommandMenu("Shield") {
            Toggle("Block Ads and Trackers", isOn: $s.adBlock).keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Toggle Shield for This Site") {
                guard let host = b?.current?.host else { return }
                s.setAllowlisted(host, !s.isAllowlisted(host))
            }
            .disabled(b == nil || !s.adBlock)
            Divider()
            Toggle("Hide Cookie Banners", isOn: $s.hideCookieBanners).disabled(!s.adBlock)
            Toggle("Skip YouTube Ads", isOn: $s.youtubeAds).disabled(!s.adBlock)
            Toggle("Block Third-Party Cookies", isOn: $s.blockThirdPartyCookies)
            Toggle("Remove Tracking from Links", isOn: $s.stripTracking)
            Divider()
            Button("Downloads") { library(.downloads) }.keyboardShortcut("l", modifiers: [.command, .option])
        }
    }

    private func library(_ section: LibraryView.Section) {
        LibraryView.requestedSection = section
        openWindow(id: "library")
    }

    private func findAgain(backwards: Bool) {
        guard let b else { return }
        if b.findVisible {
            NotificationCenter.default.post(name: .findAgain, object: backwards)
        } else {
            b.showFind()
        }
    }
}
