import SwiftUI
import UniformTypeIdentifiers

/// Saved accounts under a focused sign-in field.
struct LoginMenuView: View {
    @ObservedObject var tab: Tab
    let menu: Tab.LoginMenu
    @State private var hover: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let strong = menu.strongPassword {
                Button { tab.fillStrong(strong) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key.viewfinder").foregroundStyle(.tint).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Use Strong Password").font(.system(size: 13, weight: .medium))
                            Text(strong).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(hover == "strong" ? Color.accentColor.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? "strong" : nil }
            }
            ForEach(menu.logins) { login in
                Button { tab.fill(login) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(.tint).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login.username.isEmpty ? L("(no username)") : login.username).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(login.host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(hover == login.id ? Color.accentColor.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? login.id : nil }
            }
            if let ext = ExternalPasswordManager.current {
                if !menu.logins.isEmpty { Divider() }
                ExternalManagerRow(manager: ext)
            }
            Divider()
            SettingsLink {
                Label("Manage Passwords…", systemImage: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(height: 30)
            }
            .buttonStyle(.plain)
        }
        .frame(width: menu.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .offset(x: menu.origin.x, y: menu.origin.y)
        .onExitCommand { tab.loginMenu = nil }
    }
}

private struct ExternalManagerRow: View {
    let manager: ExternalPasswordManager

    var body: some View {
        Button { manager.open() } label: {
            HStack(spacing: 10) {
                Image(nsImage: manager.icon).resizable().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    switch manager.fill {
                    case .shortcut(let keys) where !keys.isEmpty:
                        Text(String(format: L("Fill with %@: press %@"), manager.name, keys)).font(.system(size: 12.5, weight: .medium))
                    case .shortcut:
                        Text(String(format: L("Fill with %@: use its Auto-Type shortcut"), manager.name)).font(.system(size: 12.5, weight: .medium))
                    case .openApp:
                        Text(String(format: L("Open %@ to copy your password"), manager.name)).font(.system(size: 12.5, weight: .medium))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Save password?" after a sign-in.
struct SavePasswordBanner: View {
    @ObservedObject var tab: Tab
    let pending: Tab.PendingLogin

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").font(.system(size: 18)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.isUpdate ? L("Update the saved password?") : L("Save this password?")).font(.system(size: 13, weight: .semibold))
                Text(pending.username.isEmpty ? pending.host : "\(pending.username) · \(pending.host)")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if !pending.isUpdate {
                Button("Never for This Site") { tab.neverSavePending() }.buttonStyle(.borderless).font(.system(size: 12))
            }
            Button("Not Now") { tab.pendingSave = nil }
            Button(pending.isUpdate ? "Update" : "Save") { tab.savePending() }.buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Warning shown when a password field appears on an unencrypted page.
struct InsecurePasswordBanner: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("This page isn't secure. Passwords you type here can be read by others on your network.")
                .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { tab.insecureWarning = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: 560)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.4)))
        .padding(10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Covers a locked window: a private one after Lumen goes to the background, or any window locked from the File menu.
struct PrivateLockView: View {
    @EnvironmentObject var b: BrowserState

    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI, blending: .withinWindow)
            Color(red: 0.2, green: 0.12, blue: 0.36).opacity(0.5)
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.white)
                Text(b.isPrivate ? "Private window locked" : "Window locked").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text("Unlock with Touch ID or your Mac password to see these tabs.").foregroundStyle(.white.opacity(0.75))
                Button("Unlock") { b.unlock() }.controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onAppear { if NSApp.isActive && !b.lockedByUser { b.unlock() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Only the front window asks, so several locked windows don't stack Touch ID prompts,
            // and a window you locked yourself waits for you.
            DispatchQueue.main.async { if b.window?.isKeyWindow == true && !b.lockedByUser { b.unlock() } }
        }
    }
}

// MARK: - Settings

struct PasswordsPane: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var store = PasswordStore.shared
    @State private var query = ""
    @State private var revealed: [String: String] = [:]
    @State private var message: String?
    @State private var managers = ExternalPasswordManager.detect()

    private var filtered: [SavedLogin] {
        let q = query.lowercased()
        return q.isEmpty ? store.logins : store.logins.filter { $0.host.contains(q) || $0.username.lowercased().contains(q) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Password manager", selection: $s.passwordManager) {
                    Text("Lumen (Keychain and Touch ID)").tag("")
                    ForEach(managers) { m in Text(m.name).tag(m.id) }
                }
                Toggle("Offer to save passwords", isOn: $s.savePasswords).disabled(!s.passwordManager.isEmpty)
                Toggle("Suggest saved passwords on sign-in pages", isOn: $s.autofillPasswords)
                Toggle(isOn: $s.suggestStrongPasswords) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggest strong passwords")
                        Text("On sign-up and change-password pages, offer a random password like abcdEf-ghijk2-lmnopq.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Passwords are stored in your Mac's Keychain, encrypted by macOS. Lumen asks for Touch ID or your Mac password before filling or showing one.")
            }

            Section {
                if store.logins.isEmpty {
                    Text("No saved passwords yet.").foregroundStyle(.secondary)
                } else {
                    TextField("Search passwords", text: $query)
                    ForEach(filtered) { login in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(login.host)
                                Text(login.username.isEmpty ? L("(no username)") : login.username).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let pw = revealed[login.id] {
                                Text(pw).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            }
                            Button { toggleReveal(login) } label: { Image(systemName: revealed[login.id] == nil ? "eye" : "eye.slash") }
                                .buttonStyle(.borderless).help(L("Show password"))
                            Button { copy(login) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help(L("Copy password"))
                            Button { store.delete(login) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help(L("Delete"))
                        }
                    }
                }
            } header: {
                Text("Saved passwords")
            }

            Section {
                HStack {
                    Button("Import from CSV…", action: importCSV)
                    Button("Export to CSV…", action: exportCSV).disabled(store.logins.isEmpty)
                }
            } header: {
                Text("Apple Passwords and other managers")
            } footer: {
                Text("To bring passwords from the Passwords app: in Passwords choose File › Export All Passwords, then import the file here. To send Lumen's passwords to Passwords, export them and choose File › Import Passwords there. CSV files aren't encrypted: delete them afterwards.")
            }

            if !s.neverSaveHosts.isEmpty {
                Section("Never save passwords for") {
                    ForEach(s.neverSaveHosts, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button { s.neverSaveHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.reload(); managers = ExternalPasswordManager.detect() }
        .onDisappear { revealed = [:] }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func toggleReveal(_ login: SavedLogin) {
        if revealed[login.id] != nil { revealed[login.id] = nil; return }
        store.password(for: login, reason: String(format: L("show your password for %@"), login.host)) { revealed[login.id] = $0 }
    }

    private func copy(_ login: SavedLogin) {
        store.password(for: login, reason: String(format: L("copy your password for %@"), login.host)) { pw in
            guard let pw else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pw, forType: .string)
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let n = store.importCSV(String(decoding: data, as: UTF8.self))
        message = String(format: L("Imported %lld passwords."), n)
    }

    private func exportCSV() {
        store.authenticate(reason: L("export your passwords")) { ok in
            guard ok else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Lumen Passwords.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? store.exportCSV().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
