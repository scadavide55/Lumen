import SwiftUI

struct Toolbar: View {
    let trafficSpace: Bool
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        HStack(spacing: 4) {
            if trafficSpace { Spacer().frame(width: 72) }
            if s.tabLayout == .vertical { SidebarToggle() }
            if let tab = b.current { ToolbarContent(tab: tab) }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(WindowDragArea())
    }
}

struct ToolbarContent: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    var body: some View {
        let horizontal = s.tabLayout != .vertical
        HStack(spacing: 4) {
            NavButtons(tab: tab)
            if horizontal { Spacer(minLength: 8) }
            AddressPill(tab: tab).frame(maxWidth: horizontal ? 720 : .infinity)
            if horizontal { Spacer(minLength: 8) }
            if horizontal, let p = b.profile { ProfileBadge(profile: p, compact: true).fixedSize() }
            ExtensionButtons(tab: tab)
            ShieldButton(tab: tab)
            DownloadsButton()
            AssistantButton()
            PageMenu(tab: tab)
        }
    }
}

// MARK: - Address

struct AddressPill: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared
    private var bookmarks = Bookmarks.shared
    @State private var hover = false
    @State private var showInfo = false

    private var shownURL: URL? { tab.failedURL ?? tab.url }

    private var text: String {
        guard let u = shownURL else { return L("Search or enter address") }
        if tab.isReader { return L("Reader") + " · " + InputResolver.displayHost(u) }
        return s.showFullURL ? u.absoluteString : InputResolver.displayHost(u)
    }

    private var lock: (String, Color) {
        guard let u = shownURL else { return ("magnifyingglass", .secondary) }
        if tab.failedURL != nil { return ("exclamationmark.triangle.fill", .orange) }
        if InputResolver.isInternational(u) { return ("character.textbox", .orange) }
        switch u.scheme {
        case "https": return tab.isSecure ? ("lock.fill", .secondary) : ("lock.trianglebadge.exclamationmark", .orange)
        case "http": return ("exclamationmark.triangle", .orange)
        case "file": return ("doc", .secondary)
        default: return ("globe", .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { showInfo.toggle() } label: {
                Image(systemName: lock.0).font(.system(size: 11, weight: .medium)).foregroundStyle(lock.1).frame(width: 16)
            }
            .buttonStyle(.plain)
            .disabled(shownURL == nil)
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { SiteInfoPopover(tab: tab) }
            .help("Site information")

            Text(text)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(shownURL == nil ? .secondary : .primary)
            Spacer(minLength: 4)

            if tab.url != nil && abs(tab.zoom - 1) > 0.01 {
                Button { tab.zoom(0) } label: {
                    Text("\(Int((tab.zoom * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Reset zoom"))
            }

            if tab.url != nil && (hover || tab.isReader) {
                Button { tab.toggleReader() } label: {
                    Image(systemName: tab.isReader ? "doc.plaintext.fill" : "doc.plaintext").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.isReader ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help("Reader (⇧⌘R)")
            }
            if tab.url != nil && (hover || bookmarks.contains(tab.url)) {
                Button { bookmarks.toggle(url: tab.url, title: tab.title) } label: {
                    Image(systemName: bookmarks.contains(tab.url) ? "star.fill" : "star").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(bookmarks.contains(tab.url) ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                .help("Bookmark (⌘D)")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.085 : 0.055)))
        .overlay(alignment: .bottom) {
            if tab.isLoading { LoadingLine(load: tab.load).padding(.horizontal, 6) }
        }
        .contentShape(Rectangle())
        .onTapGesture { b.showPalette(shownURL?.absoluteString) }
        .onHover { hover = $0 }
        .help(shownURL?.absoluteString ?? L("Search or enter address (⌘L)"))
    }
}

/// The progress line of a loading page; it watches only the progress, not the whole tab.
struct LoadingLine: View {
    var load: LoadProgress
    var body: some View { ProgressLine(progress: load.value) }
}

struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { g in
            Capsule()
                .fill(.tint)
                .frame(width: max(8, g.size.width * progress), height: 2)
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2)
    }
}

// MARK: - Shield

struct ShieldButton: View {
    var tab: Tab
    @Bindable var s = Settings.shared
    @State private var show = false

    var body: some View {
        let on = tab.shieldsUp
        IconButton(systemName: on ? "shield.lefthalf.filled" : "shield.slash",
                   help: on ? "Tacet Shield is on" : "Tacet Shield is off for this page",
                   tint: on ? s.accent : nil) { show.toggle() }
            .popover(isPresented: $show, arrowEdge: .bottom) { ShieldPopover(tab: tab) }
    }
}

struct ShieldPopover: View {
    var tab: Tab
    @Bindable private var s = Settings.shared
    private var blocker = ContentBlocker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: tab.shieldsUp ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 24))
                    .foregroundStyle(tab.shieldsUp ? s.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tacet Shield").font(.headline)
                    Text(tab.host.map { InputResolver.displayHost(URL(string: "https://" + $0)) } ?? L("No site loaded"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let host = tab.host {
                Toggle("Protection on this site", isOn: Binding(
                    get: { !s.isAllowlisted(host) },
                    set: { s.setAllowlisted(host, !$0) }))
                    .disabled(!s.adBlock)
            }
            Divider()
            Toggle("Block ads and trackers", isOn: $s.adBlock)
            Toggle("Hide cookie banners", isOn: $s.hideCookieBanners).disabled(!s.adBlock)
            Toggle("Skip YouTube ads", isOn: $s.youtubeAds).disabled(!s.adBlock)
            Toggle("Block third-party cookies", isOn: $s.blockThirdPartyCookies)
            Toggle("Remove tracking from links", isOn: $s.stripTracking)
            HStack {
                Text(s.adBlock ? LocalizedStringKey("\(blocker.ruleCount.formatted()) rules active") : "Blocking is off")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Text("Settings…") }.controlSize(.small)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Site information

struct SiteInfoPopover: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @State private var cleared = false

    var body: some View {
        let url = tab.failedURL ?? tab.url
        let secure = url?.scheme == "https" && tab.isSecure
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: secure ? "lock.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(secure ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(secure ? LocalizedStringKey("Connection is secure") : "Connection is not secure").font(.headline)
                    Text(InputResolver.displayHost(url)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if InputResolver.isInternational(url) {
                Label("This address uses letters from other alphabets, which can be made to look like a familiar site. Check that it's the site you meant to visit.", systemImage: "character.textbox")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if secure, let cert = tab.certificateSummary {
                Label(cert, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
            } else if url?.scheme == "http" {
                Text("Anything you send to this site, like passwords or card numbers, could be read by others.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("Zoom")
                Spacer()
                Button { tab.zoom(-1) } label: { Image(systemName: "minus") }
                Text("\(Int((tab.zoom * 100).rounded()))%").monospacedDigit().frame(width: 44)
                Button { tab.zoom(1) } label: { Image(systemName: "plus") }
                Button("Reset") { tab.zoom(0) }
            }
            .controlSize(.small)
            if let host = tab.host {
                Button(cleared ? LocalizedStringKey("Site data cleared") : "Clear Cookies and Site Data…") {
                    Dialogs.confirm(b.window, title: String(format: L("Clear data for %@?"), InputResolver.displayHost(url)),
                                    message: L("You'll be signed out of this site and its saved preferences will be removed."),
                                    ok: L("Clear")) { ok in
                        guard ok else { return }
                        DataCleaner.clearSite(host, store: b.dataStore) {
                            cleared = true
                            tab.reload()
                        }
                    }
                }
                .disabled(cleared)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Downloads

struct DownloadsButton: View {
    private var dm = DownloadManager.shared
    @State private var show = false

    var body: some View {
        if !dm.items.isEmpty {
            IconButton(systemName: dm.active.isEmpty ? "arrow.down.circle" : "arrow.down.circle.dotted",
                       help: "Downloads (⌥⌘L)", tint: dm.unseen ? .accentColor : nil) {
                show.toggle()
                dm.unseen = false
            }
            .overlay {
                if !dm.active.isEmpty {
                    Circle().trim(from: 0, to: dm.overallFraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 20, height: 20)
                        .allowsHitTesting(false)
                }
            }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                DownloadsList().frame(width: 360, height: 320)
            }
        }
    }
}

struct DownloadsList: View {
    private var dm = DownloadManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { dm.clearFinished() }.disabled(dm.items.allSatisfy { $0.state == .active })
            }
            .padding(12)
            Divider()
            if dm.items.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(dm.items) { DownloadRow(item: $0) }
                    }
                }
            }
        }
    }
}

struct DownloadRow: View {
    var item: DownloadItem
    private var dm: DownloadManager { .shared }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(1).truncationMode(.middle)
                if item.state == .active {
                    ProgressView(value: item.fraction).controlSize(.small)
                }
                Text(item.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if item.state == .active {
                IconButton(systemName: "xmark.circle.fill", help: "Cancel") { dm.cancel(item) }
            } else if item.canResume {
                IconButton(systemName: "arrow.clockwise.circle.fill", help: "Resume") { dm.resume(item) }
            } else if item.state == .finished {
                IconButton(systemName: "magnifyingglass", help: "Show in Finder") { dm.reveal(item) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { dm.open(item) }
        .contextMenu {
            Button("Open") { dm.open(item) }.disabled(item.state != .finished)
            if item.canResume { Button("Resume") { dm.resume(item) } }
            Button("Show in Finder") { dm.reveal(item) }.disabled(item.destination == nil)
            if let src = item.source {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(src.absoluteString, forType: .string)
                }
            }
        }
    }
}

// MARK: - Page menu

struct PageMenu: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Button(tab.isReader ? LocalizedStringKey("Exit Reader") : "Reader") { tab.toggleReader() }.disabled(tab.url == nil)
            if !b.isPrivate {
                Button("Save for Offline") { tab.saveForOffline() }.disabled(tab.url == nil)
            }
            Button("Find on Page…") { b.showFind() }.disabled(tab.url == nil)
            if tab.translatedFrom != nil {
                Button("Show Original") { tab.showOriginal() }
            } else {
                Button("Translate Page") { tab.translatePage() }.disabled(tab.url == nil)
            }
            Button(tab.readingAloud ? LocalizedStringKey("Stop Reading Aloud") : "Read Aloud") { ReadAloud.shared.toggle(tab) }.disabled(tab.url == nil)
            Button("Focus Mode") { b.focusMode = true }
            Menu("Zoom") {
                Button("Zoom In") { tab.zoom(1) }
                Button("Zoom Out") { tab.zoom(-1) }
                Button("Actual Size") { tab.zoom(0) }
            }
            Divider()
            if let url = tab.url {
                ShareLink(item: url)
                Button("Copy Link") { copy(url) }
                Button("Copy Link Without Tracking") { copy(URLCleaner.clean(url) ?? url) }
            }
            Button("Print…") { tab.printPage() }.disabled(tab.url == nil)
            Button("Export as PDF…") { tab.exportPDF() }.disabled(tab.url == nil)
            Button("Customize This Site…") { b.customizingSite = true }.disabled(tab.host == nil || tab.isReader)
            Button("Install as App…") { b.showInstallApp = true }.disabled(tab.url == nil || WebApp.isActive)
            Button("Take Screenshot of Page") { tab.screenshot() }.disabled(tab.url == nil)
            Divider()
            Button(b.splitTab == nil ? LocalizedStringKey("Split View with New Tab") : "Close Split View") {
                b.splitTab == nil ? b.splitWithNewTab() : b.closeSplit()
            }
            Button(tab.isPinned ? LocalizedStringKey("Unpin Tab") : "Pin Tab") { b.togglePin(tab) }
            Button(tab.isMuted ? LocalizedStringKey("Unmute Tab") : "Mute Tab") { tab.setMuted(!tab.isMuted) }
            Divider()
            Button("History and Bookmarks") {
                LibraryView.requestedSection = .history
                openWindow(id: "library")
            }
            Button("Reading List") {
                LibraryView.requestedSection = .readingList
                openWindow(id: "library")
            }
            SettingsLink { Text("Settings…") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 26)
        .foregroundStyle(.secondary)
        .help("More")
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
