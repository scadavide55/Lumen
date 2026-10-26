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
                    ForEach(entries) { entry in
                        switch entry {
                        case .header(let g): GroupHeader(group: g)
                        case .tab(let t, let grouped): TabRow(tab: t, grouped: grouped)
                        }
                    }
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

/// A row in the sidebar's tab list: a group header or a tab.
enum SidebarEntry: Identifiable {
    case header(TabGroup)
    case tab(Tab, grouped: Bool)

    var id: String {
        switch self {
        case .header(let g): "g" + g.id.uuidString
        case .tab(let t, _): t.id.uuidString
        }
    }
}

extension Sidebar {
    var entries: [SidebarEntry] {
        var out: [SidebarEntry] = []
        var seen = Set<UUID>()
        for t in b.regularTabs {
            if let gid = t.groupID, let g = b.groups.first(where: { $0.id == gid }) {
                if !seen.contains(gid) { seen.insert(gid); out.append(.header(g)) }
                if !g.collapsed { out.append(.tab(t, grouped: true)) }
            } else {
                out.append(.tab(t, grouped: false))
            }
        }
        return out
    }
}

struct GroupHeader: View {
    let group: TabGroup
    @EnvironmentObject var b: BrowserState
    @State private var hover = false
    @State private var renaming = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Circle().fill(group.tint).frame(width: 8, height: 8)
            if renaming {
                TextField("Group name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { renaming = false }
            } else {
                Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(b.tabs(in: group).count)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(group.tint.opacity(hover ? 0.16 : 0.09)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename() }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { b.toggleCollapsed(group.id) } }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Rename Group…") { startRename() }
            Menu("Colour") {
                ForEach(0..<TabGroup.colors.count, id: \.self) { i in
                    Button { b.setColor(group.id, i) } label: { Text(Self.colorNames[i]) }
                }
            }
            Button(group.collapsed ? "Expand Group" : "Collapse Group") { b.toggleCollapsed(group.id) }
            Divider()
            Button("Ungroup Tabs") { b.ungroup(group.id) }
            Button("Close Group") { b.closeGroup(group.id) }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let last = b.tabs(in: group).last else { return false }
            return b.handleDrop(items, on: last, placement: .group, pinned: false)
        }
        .help(L("Click to collapse, double-click to rename"))
    }

    static let colorNames = [L("Blue"), L("Purple"), L("Pink"), L("Orange"), L("Green"), L("Teal"), L("Yellow"), L("Grey")]

    private func startRename() {
        name = group.name
        renaming = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        b.renameGroup(group.id, name)
        renaming = false
    }
}

struct TabRow: View {
    @ObservedObject var tab: Tab
    var grouped = false
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
                .help(tab.isMuted ? LocalizedStringKey("Unmute tab") : "Mute tab")
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
        .overlay(alignment: .leading) {
            if grouped, let g = b.groups.first(where: { $0.id == tab.groupID }) {
                Capsule().fill(g.tint).frame(width: 2.5).padding(.vertical, 7).offset(x: -6)
            }
        }
        .padding(.leading, grouped ? 10 : 0)
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
        .dropDestination(for: String.self) { items, location in
            let h: CGFloat = s.compactTabs ? 28 : 34
            let placement: BrowserState.DropPlacement = location.y < h * 0.28 ? .before : (location.y > h * 0.72 ? .after : .group)
            return b.handleDrop(items, on: tab, placement: placement, pinned: false)
        }
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
        Button(tab.isPinned ? LocalizedStringKey("Unpin Tab") : "Pin Tab") { b.togglePin(tab) }
        Button("Duplicate Tab") { b.duplicate(tab) }
        if tab.groupID != nil {
            Button("Remove from Group") { b.removeFromGroup(tab) }
        } else if !tab.isPinned {
            Button("Add to New Group") { b.newGroup(with: tab) }
        }
        Button(tab.isMuted ? LocalizedStringKey("Unmute Tab") : "Mute Tab") { tab.setMuted(!tab.isMuted) }
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
        Button(Bookmarks.shared.contains(tab.url) ? LocalizedStringKey("Remove Bookmark") : "Add Bookmark") {
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
        Button("Close Duplicate Tabs") { b.closeDuplicates() }
        if Settings.shared.tabLayout != .vertical {
            Button("Close Tabs to the Right") { b.closeBelow(tab) }
        } else {
            Button("Close Tabs Below") { b.closeBelow(tab) }
        }
    }
}

struct SidebarFooter: View {
    let showsDownloads: Bool
    @EnvironmentObject var b: BrowserState
    @ObservedObject private var blocker = ContentBlocker.shared
    @ObservedObject private var updates = UpdateChecker.shared
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
            if let r = updates.available {
                Button { openWindow(id: "update") } label: {
                    Text("Update").font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help(String(format: L("%@ is available."), r.name))
            }
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
    /// Compact: the strip shares the toolbar row and the selected tab shows the address.
    var compact = false
    @EnvironmentObject var b: BrowserState

    var body: some View {
        GeometryReader { geo in
            let pinned = b.pinnedTabs.count
            let visible = b.regularTabs.filter { t in !(b.groups.first { $0.id == t.groupID }?.collapsed ?? false) }
            let regular = max(1, visible.count + b.groups.count)
            let free = geo.size.width - 16 - CGFloat(pinned) * 40 - 34 - (compact ? 120 : 0)
            let width = min(240, max(compact ? 90 : 110, free / CGFloat(regular) - 4))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(stripItems) { item in
                        switch item {
                        case .tab(let t):
                            chip(t, width)
                        case .group(let g, let members):
                            HStack(spacing: 0) {
                                GroupChip(group: g, count: members.count)
                                if !g.collapsed {
                                    ForEach(Array(members.enumerated()), id: \.element.id) { i, t in
                                        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16)
                                            .opacity(t.id == b.selectedID || (i > 0 && members[i - 1].id == b.selectedID) ? 0 : 1)
                                        chip(t, width)
                                    }
                                }
                            }
                            .padding(2)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(g.tint.opacity(0.35), lineWidth: 1))
                        }
                    }
                    IconButton(systemName: "plus", help: "New tab (⌘T)") { b.newTabWithPalette() }
                }
                .padding(.horizontal, compact ? 2 : 8)
            }
        }
        .frame(height: 34)
        .padding(.bottom, compact ? 0 : 4)
    }
}

enum StripItem: Identifiable {
    case tab(Tab)
    case group(TabGroup, [Tab])
    var id: String {
        switch self {
        case .tab(let t): t.id.uuidString
        case .group(let g, _): "g" + g.id.uuidString
        }
    }
}

extension TabStrip {
    /// Tabs in order, with each group gathered into one folder-like item.
    var stripItems: [StripItem] {
        var out: [StripItem] = []
        var seen = Set<UUID>()
        for t in b.tabs {
            if !t.isPinned, let gid = t.groupID, let g = b.groups.first(where: { $0.id == gid }) {
                if seen.insert(gid).inserted { out.append(.group(g, b.tabs(in: g))) }
            } else {
                out.append(.tab(t))
            }
        }
        return out
    }

    func chip(_ t: Tab, _ width: CGFloat) -> some View {
        let selectedWide = compact && t.id == b.selectedID
        return TabChip(tab: t, width: t.isPinned ? 36 : (selectedWide ? min(420, max(220, width + 120)) : width), compact: compact)
    }
}

/// The folder of a tab group in the top bar: "Google 3 ›" when closed.
struct GroupChip: View {
    let group: TabGroup
    let count: Int
    @EnvironmentObject var b: BrowserState
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(group.name).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
            Text("\(count)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
            if group.collapsed {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.1 : (group.collapsed ? 0.06 : 0))))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { b.toggleCollapsed(group.id) } }
        .onHover { hover = $0 }
        .contextMenu {
            Button(group.collapsed ? "Expand Group" : "Collapse Group") { b.toggleCollapsed(group.id) }
            Button("Ungroup Tabs") { b.ungroup(group.id) }
            Button("Close Group") { b.closeGroup(group.id) }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let last = b.tabs(in: group).last else { return false }
            return b.handleDrop(items, on: last, placement: .group, pinned: false)
        }
        .help(L("Click to collapse, double-click to rename"))
    }
}

/// Safari's compact layout: navigation, tabs and the address in one row.
struct CompactBar: View {
    @EnvironmentObject var b: BrowserState

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 72)
            if let tab = b.current { NavButtons(tab: tab) }
            TabStrip(compact: true)
            if let tab = b.current {
                ShieldButton(tab: tab)
                DownloadsButton()
                PageMenu(tab: tab)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(WindowDragArea())
    }
}

struct TabChip: View {
    @ObservedObject var tab: Tab
    let width: CGFloat
    var compact = false
    @EnvironmentObject var s: Settings
    @EnvironmentObject var b: BrowserState
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        let selected = b.selectedID == tab.id
        let showsAddress = compact && selected && !tab.isPinned
        HStack(spacing: 6) {
            if showsAddress && !s.alwaysShowTitles && tab.url != nil {
                Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                FaviconView(tab: tab, size: 14)
            }
            if !tab.isPinned {
                Text(showsAddress && !s.alwaysShowTitles ? (tab.url.map { InputResolver.displayHost($0) } ?? L("Search or enter address")) : tab.title)
                    .font(.system(size: 12, weight: showsAddress ? .medium : .regular)).lineLimit(1)
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
        .overlay(alignment: .bottom) {
            if showsAddress && tab.isLoading {
                ProgressLine(progress: tab.progress).padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if showsAddress { b.showPalette(tab.url?.absoluteString) } else { b.select(tab) }
        }
        .onHover { hover = $0 }
        .contextMenu { TabMenu(tab: tab) }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, location in
            let placement: BrowserState.DropPlacement = tab.isPinned ? .before
                : (location.x < width * 0.25 ? .before : (location.x > width * 0.75 ? .after : .group))
            return b.handleDrop(items, on: tab, placement: placement, pinned: tab.isPinned)
        }
        .help(tab.title)
    }
}
