import SwiftUI

/// Tacet Plugins: the store. Every card says who made the plugin and whether Tacet's developer checked it.
struct PluginsView: View {
    private var store = PluginStore.shared
    @State private var query = ""
    @State private var failure: String?
    @State private var pending: PendingInstall?

    private var shown: [PluginStore.Plugin] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.catalog }
        return store.catalog.filter { p in
            [L(p.name), L(p.description), p.author ?? ""].contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if store.catalog.isEmpty {
                    VStack(spacing: 10) {
                        if store.loading {
                            ProgressView()
                        } else if let e = store.error {
                            Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Button("Try Again") { Task { await store.refresh(force: true) } }
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(shown) { p in PluginCard(plugin: p, failure: $failure) }
                    }
                    .padding(20)
                }
            }
            if let failure {
                Divider()
                HStack {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("OK") { self.failure = nil }
                }
                .font(.callout).padding(12)
            }
        }
        .frame(minWidth: 620, idealWidth: 820, minHeight: 480, idealHeight: 620)
        .task { await store.refresh() }
        .onChange(of: store.pendingExtension?.plugin.id) { _, _ in prepareExtension() }
        .sheet(item: $pending) { p in
            if #available(macOS 15.4, *) { InstallSheet(pending: p) { pending = nil } }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            EclipseMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Text("Tacet Plugins").font(.system(size: 20, weight: .bold)); BetaBadge() }
                Text("Small additions for Tacet. Every one says who made it and whether we checked it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search plugins", text: $query, prompt: Text("Search plugins")).textFieldStyle(.plain).frame(width: 160)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .padding(20)
    }

    /// Opens a plugin's app in a new tab of the front window.
    static func open(_ url: URL) {
        guard let b = WindowRegistry.shared.lastFocused.flatMap({ $0.isPrivate ? nil : $0 }) ?? WindowRegistry.shared.browsers.first else { return }
        b.newTab(url: url)
        b.window?.makeKeyAndOrderFront(nil)
    }

    /// An extension from another browser's store was downloaded: show what it can do before adding it.
    private func prepareExtension() {
        guard let (plugin, folder) = store.pendingExtension, #available(macOS 15.4, *) else { return }
        store.pendingExtension = nil
        Task { @MainActor in
            do {
                let e = try await Extensions.shared.extensionFrom(.folder(folder.path))
                pending = PendingInstall(extension: e, source: .folder(folder.path), discard: folder)
            } catch {
                Extensions.shared.discardImported(folder)
                failure = String(format: L("“%@” couldn't be read: %@"), L(plugin.name), error.localizedDescription)
            }
        }
    }
}

struct PluginCard: View {
    let plugin: PluginStore.Plugin
    @Binding var failure: String?
    private var store = PluginStore.shared
    private var ext = Extensions.shared

    init(plugin: PluginStore.Plugin, failure: Binding<String?>) {
        self.plugin = plugin
        _failure = failure
    }

    private var installed: PluginStore.Installed? { store.installed[plugin.id] }
    /// An extension counts as added once Extensions lists it under the same name.
    private var extensionAdded: Bool { plugin.isExtension && ext.installed.contains { $0.name == plugin.name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: plugin.icon ?? "puzzlepiece.extension")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(plugin.name)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(plugin.byLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    VerifiedBadge(verified: plugin.isVerified)
                    if plugin.developer != nil || plugin.website != nil {
                        HStack(spacing: 6) {
                            if let dev = plugin.developer {
                                Text(String(format: L("Developer: %@"), dev)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let site = plugin.website, let url = URL(string: site) {
                                Link(site.replacingOccurrences(of: "https://", with: ""), destination: url).font(.caption)
                            }
                        }
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(L(plugin.description)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                if plugin.isExtension && !Extensions.isSupported {
                    Text("Needs macOS 15.4 or later").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.working.contains(plugin.id) {
                    if let p = store.progress[plugin.id], let size = plugin.app?.downloadSize {
                        Text(String(format: L("Downloading %@ of %@"),
                                    ByteCountFormatter.string(fromByteCount: Int64(Double(size) * p), countStyle: .file),
                                    ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        ProgressView(value: p).frame(width: 90)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if let installed, !plugin.isExtension {
                    if let start = plugin.startURL, installed.enabled {
                        Button("Open") { PluginsView.open(start) }.controlSize(.small)
                    }
                    Toggle("On", isOn: Binding(get: { installed.enabled }, set: { store.setEnabled(plugin.id, $0) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    Button("Remove") { store.remove(plugin.id) }.controlSize(.small)
                } else if extensionAdded {
                    Label("Added", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                } else {
                    if let size = plugin.app?.downloadSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(plugin.isExtension ? LocalizedStringKey("Add…") : "Add") { add() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(plugin.isExtension && !Extensions.isSupported)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private func add() {
        Task { @MainActor in
            do { try await store.install(plugin) } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// "✓ Verified by Tacet" in green, or "Works, but not verified" in orange.
struct VerifiedBadge: View {
    let verified: Bool

    var body: some View {
        Label(verified ? LocalizedStringKey("Verified by Tacet") : "Works, but not verified",
              systemImage: verified ? "checkmark.seal.fill" : "xmark.seal.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(verified ? Color.green : Color.orange)
            .help(verified ? L("Tacet's developer read this plugin and checked what it does.")
                  : L("It works in Tacet, but Tacet's developer hasn't checked what it does. Add it only if you trust who made it."))
    }
}
