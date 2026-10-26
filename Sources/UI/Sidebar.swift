import SwiftUI

struct Sidebar: View {
    let showsControls: Bool
    @EnvironmentObject var b: BrowserState
    @EnvironmentObject var s: Settings

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                if s.sidebarSide == .left { Spacer().frame(width: 70) }
                Spacer(minLength: 0)
                if showsControls {
                    SidebarToggle()
                    if let tab = b.current { NavButtons(tab: tab) }
                }
            }
            .frame(height: 28)
            .background(WindowDragArea())

            if showsControls, let tab = b.current {
                AddressPill(tab: tab)
            }
            if b.isPrivate { PrivateBadge() }
            if !b.pinnedTabs.isEmpty { PinnedGrid() }

            ScrollView {
                LazyVStack(spacing: 2) {
                    NewTabRow()
                    ForEach(b.regularTabs) { TabRow(tab: $0) }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .dropDestination(for: String.self) { items, _ in b.handleDrop(items, before: nil, pinned: false) }

            SidebarFooter(showsDownloads: showsControls)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct SidebarToggle: View {
    @EnvironmentObject var b: BrowserState
    @EnvironmentObject var s: Settings

    var body: some View {
        IconButton(systemName: s.sidebarSide == .left ? "sidebar.left" : "sidebar.right", help: "Toggle sidebar (⌘S)") {
            b.peekSidebar = false
            b.sidebarVisible.toggle()
        }
    }
}

struct NavButtons: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "chevron.left", help: "Back (⌘[)") { tab.goBack() }.disabled(!tab.canGoBack)
            IconButton(systemName: "chevron.right", help: "Forward (⌘])") { tab.goForward() }.disabled(!tab.canGoForward)
            IconButton(systemName: tab.isLoading ? "xmark" : "arrow.clockwise", help: tab.isLoading ? "Stop" : "Reload (⌘R)") {
                tab.isLoading ? tab.stop() : tab.reload()
            }
            .disabled(tab.url == nil && tab.failedURL == nil)
        }
    }
}

struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eyeglasses")
            Text("Private window").font(.system(size: 11.5, weight: .medium))
            Spacer()
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("History, cookies and site data from this window are forgotten when you close it.")
    }
}

struct NewTabRow: View {
    @EnvironmentObject var b: BrowserState
    @EnvironmentObject var s: Settings
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 16)
            Text("New Tab").font(.system(size: 12.5))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: s.compactTabs ? 28 : 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { b.newTabWithPalette() }
        .onHover { hover = $0 }
        .help("New tab (⌘T)")
    }
}

struct TabRow: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var b: BrowserState
    @EnvironmentObject var s: Settings
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    private var selected: Bool { b.selectedID == tab.id }

    var body: some View {
        HStack(spacing: 8) {
            FaviconView(tab: tab)
            Text(tab.title)
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(tab.isHibernated && !selected ? .secondary : .primary)
            Spacer(minLength: 0)
            if tab.isPlayingAudio || tab.isMuted {
                Button { tab.setMuted(!tab.isMuted) } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tab.isMuted ? "Unmute tab" : "Mute tab")
            }
            if b.splitID == tab.id {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if hover || selected {
                Button { b.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: s.compactTabs ? 28 : 34)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.white.opacity(scheme == .dark ? 0.12 : 0.75) : Color.primary.opacity(hover ? 0.06 : 0))
                .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 1, y: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { b.select(tab) }
        .onHover { hover = $0 }
        .contextMenu { TabMenu(tab: tab) }
        .draggable(tab.id.uuidString) {
            Label(tab.title, systemImage: "globe").padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in b.handleDrop(items, before: tab, pinned: false) }
        .help(tab.url?.absoluteString ?? tab.title)
    }
}

struct PinnedGrid: View {
    @EnvironmentObject var b: BrowserState

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
            ForEach(b.pinnedTabs) { PinnedTile(tab: $0) }
        }
        .dropDestination(for: String.self) { items, _ in b.handleDrop(items, before: nil, pinned: true) }
    }
}

struct PinnedTile: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var b: BrowserState
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        let selected = b.selectedID == tab.id
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.white.opacity(scheme == .dark ? 0.14 : 0.8) : Color.primary.opacity(hover ? 0.1 : 0.06))
            .frame(height: 40)
            .overlay(FaviconView(tab: tab, size: 18))
            .overlay(alignment: .topTrailing) {
                if tab.isPlayingAudio || tab.isMuted {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 8)).foregroundStyle(.secondary).padding(4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { b.select(tab) }
            .onHover { hover = $0 }
            .contextMenu { TabMenu(tab: tab) }
            .draggable(tab.id.uuidString)
            .dropDestination(for: String.self) { items, _ in b.handleDrop(items, before: tab, pinned: true) }
            .help(tab.title)
    }
}

struct TabMenu: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var b: BrowserState

    var body: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { b.togglePin(tab) }
        Button("Duplicate Tab") { b.duplicate(tab) }
        Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.setMuted(!tab.isMuted) }
        if b.selectedID != tab.id {
            if b.splitID == tab.id {
                Button("Close Split View") { b.closeSplit() }
            } else {
                Button("Open in Split View") { b.openSplit(tab) }
            }
        }
        Divider()
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
        }
        .disabled(tab.url == nil)
        Button(Bookmarks.shared.contains(tab.url) ? "Remove Bookmark" : "Add Bookmark") {
            Bookmarks.shared.toggle(url: tab.url, title: tab.title)
        }
        .disabled(tab.url == nil)
        Button("Reload Tab") { tab.reload() }
        if !tab.isHibernated && !tab.isSelected {
            Button("Hibernate Tab") { tab.hibernate() }
        }
        Divider()
        Button("Close Tab") { b.close(tab) }
        Button("Close Other Tabs") { b.closeOthers(tab) }
        Button("Close Tabs Below") { b.closeBelow(tab) }
    }
}

struct SidebarFooter: View {
    let showsDownloads: Bool
    @EnvironmentObject var b: BrowserState
    @ObservedObject private var blocker = ContentBlocker.shared
    @ObservedObject private var s = Settings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "books.vertical", help: "History and bookmarks (⌘Y)") {
                LibraryView.requestedSection = .history
                openWindow(id: "library")
            }
            if showsDownloads { DownloadsButton() }
            Spacer()
            if s.adBlock {
                Label("\(blocker.ruleCount.formatted())", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Lumen Shield is on with \(blocker.ruleCount.formatted()) rules")
            }
            Spacer()
            IconButton(systemName: "eyeglasses", help: "New private window (⇧⌘N)") { openWindow(id: "private") }
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
    }
}

// MARK: - Horizontal tabs

struct TabStrip: View {
    @EnvironmentObject var b: BrowserState

    var body: some View {
        GeometryReader { geo in
            let pinned = b.pinnedTabs.count
            let regular = max(1, b.regularTabs.count)
            let free = geo.size.width - 16 - CGFloat(pinned) * 40 - 34
            let width = min(240, max(110, free / CGFloat(regular) - 4))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(b.tabs) { TabChip(tab: $0, width: $0.isPinned ? 36 : width) }
                    IconButton(systemName: "plus", help: "New tab (⌘T)") { b.newTabWithPalette() }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(height: 34)
        .padding(.bottom, 4)
    }
}

struct TabChip: View {
    @ObservedObject var tab: Tab
    let width: CGFloat
    @EnvironmentObject var b: BrowserState
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        let selected = b.selectedID == tab.id
        HStack(spacing: 6) {
            FaviconView(tab: tab, size: 14)
            if !tab.isPinned {
                Text(tab.title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                if tab.isPlayingAudio || tab.isMuted {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .onTapGesture { tab.setMuted(!tab.isMuted) }
                }
                if hover || selected {
                    Button { b.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, tab.isPinned ? 0 : 9)
        .frame(width: width, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.white.opacity(scheme == .dark ? 0.12 : 0.75) : Color.primary.opacity(hover ? 0.07 : 0.03)))
        .contentShape(Rectangle())
        .onTapGesture { b.select(tab) }
        .onHover { hover = $0 }
        .contextMenu { TabMenu(tab: tab) }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in b.handleDrop(items, before: tab, pinned: tab.isPinned) }
        .help(tab.title)
    }
}
