import SwiftUI
import UniformTypeIdentifiers

final class LibraryRouter: ObservableObject {
    static let shared = LibraryRouter()
    @Published var section = LibraryView.Section.history
}

struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case history, bookmarks, downloads
        var id: String { rawValue }
        var label: String { L(rawValue.capitalized) }
        var symbol: String { ["history": "clock", "bookmarks": "book", "downloads": "arrow.down.circle"][rawValue]! }
    }

    static var requestedSection: Section {
        get { LibraryRouter.shared.section }
        set { LibraryRouter.shared.section = newValue }
    }

    @ObservedObject private var router = LibraryRouter.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: Binding(get: { router.section }, set: { if let v = $0 { router.section = v } })) { s in
                Label(s.label, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch router.section {
            case .history: HistoryList(open: open)
            case .bookmarks: BookmarkList(open: open)
            case .downloads: DownloadsList()
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .tint(Settings.shared.accent)
    }

    private func open(_ urls: [URL]) {
        if !WindowRegistry.shared.open(urls) { openWindow(id: "main") }
    }
}

// MARK: - History

struct HistoryList: View {
    let open: ([URL]) -> Void
    @ObservedObject private var history = History.shared
    @State private var query = ""
    @State private var selection = Set<UUID>()
    /// Search results, found off the main thread; nil while the search field is empty.
    @State private var results: [HistoryEntry]?

    private var groups: [(Date, [HistoryEntry])] {
        let list = query.isEmpty ? Array(history.entries.prefix(3000)) : (results ?? [])
        let cal = Calendar.current
        let grouped = Dictionary(grouping: list) { cal.startOfDay(for: $0.date) }
        return grouped.sorted { $0.key > $1.key }.map { ($0.key, $0.value.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        let groups = groups
        List(selection: $selection) {
            ForEach(groups, id: \.0) { day, entries in
                SwiftUI.Section(day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                    ForEach(entries) { e in
                        HStack(spacing: 10) {
                            Group {
                                if let icon = Favicons.shared.cached(e.url.host) {
                                    Image(nsImage: icon).resizable()
                                } else {
                                    Image(systemName: "globe").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title.isEmpty ? e.url.absoluteString : e.title).lineLimit(1)
                                Text(e.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(e.id)
                    }
                }
            }
        }
        .overlay {
            if groups.isEmpty && (query.isEmpty || results != nil) {
                ContentUnavailableView(query.isEmpty ? LocalizedStringKey("No History") : "No Results", systemImage: "clock")
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Open") { open(urls(ids)) }
            Button("Copy Link") { copy(urls(ids)) }
            Divider()
            Button("Delete") { history.remove(ids) }
        } primaryAction: { ids in
            open(urls(ids))
        }
        .onDeleteCommand { history.remove(selection) }
        .searchable(text: $query, placement: .toolbar, prompt: "Search history")
        .task(id: "\(query)\u{1}\(history.entries.count)") {
            guard !query.isEmpty else { results = nil; return }
            // Waits for a pause in typing; a newer keystroke cancels this one.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await history.filterInBackground(query)
            if !Task.isCancelled { results = found }
        }
        .toolbar {
            Menu("Clear History") {
                Button("Last Hour") { history.clear(since: Date().addingTimeInterval(-3600)) }
                Button("Today") { history.clear(since: Calendar.current.startOfDay(for: Date())) }
                Button("All History") { history.clear() }
            }
        }
        .navigationTitle("History")
    }

    private func urls(_ ids: Set<UUID>) -> [URL] {
        history.entries.filter { ids.contains($0.id) }.map(\.url)
    }

    private func copy(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Bookmarks

struct BookmarkList: View {
    let open: ([URL]) -> Void
    @ObservedObject private var bookmarks = Bookmarks.shared
    @State private var selection = Set<UUID>()
    @State private var renaming: Bookmark?
    @State private var newTitle = ""
    @State private var message: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(bookmarks.items) { b in
                HStack(spacing: 10) {
                    Group {
                        if let icon = Favicons.shared.cached(b.url.host) {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                    }
                    .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.title).lineLimit(1)
                        Text(b.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .tag(b.id)
            }
            .onMove { bookmarks.move(from: $0, to: $1) }
        }
        .overlay {
            if bookmarks.items.isEmpty {
                ContentUnavailableView("No Bookmarks", systemImage: "book",
                                       description: Text("Press ⌘D on any page, or import bookmarks from another browser."))
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Open") { open(urls(ids)) }
            if ids.count == 1, let b = bookmarks.items.first(where: { ids.contains($0.id) }) {
                Button("Rename…") { newTitle = b.title; renaming = b }
            }
            Divider()
            Button("Delete") { bookmarks.remove(ids) }
        } primaryAction: { ids in
            open(urls(ids))
        }
        .onDeleteCommand { bookmarks.remove(selection) }
        .toolbar {
            Button("Import…", action: importFile).help("Import bookmarks exported from Safari, Chrome or Firefox (HTML)")
            Button("Export…", action: exportFile)
        }
        .alert("Rename Bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Save") { if let r = renaming { bookmarks.rename(r.id, to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .navigationTitle("Bookmarks")
    }

    private func urls(_ ids: Set<UUID>) -> [URL] {
        bookmarks.items.filter { ids.contains($0.id) }.map(\.url)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let n = bookmarks.importHTML(String(decoding: data, as: UTF8.self))
        message = n == 1 ? L("Imported 1 bookmark.") : String(format: L("Imported %lld bookmarks."), n)
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "Lumen Bookmarks.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? bookmarks.exportHTML().write(to: url, atomically: true, encoding: .utf8)
    }
}
