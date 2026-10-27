import SwiftUI

/// The assistant filling the window, like a chat app: past chats on the left, the conversation in the middle.
struct AssistantFullView: View {
    @Environment(BrowserState.self) var b
    @Bindable private var s = Settings.shared
    private var history = AssistantHistory.shared
    @State private var query = ""
    @State private var listVisible = true
    @State private var confirmClear = false

    private var chat: AssistantChat { b.assistant }
    private var configured: Bool { !s.aiProvider.needsKey || AIKeys.has(s.aiProvider) }
    private static let column: CGFloat = 760

    private var shown: [AssistantHistory.Summary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? history.chats : history.chats.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var title: String {
        history.chats.first { $0.id == chat.id }?.title ?? L("New Chat")
    }

    var body: some View {
        HStack(spacing: 0) {
            if listVisible {
                sidebar.frame(width: 260).transition(.move(edge: .leading))
                Divider().opacity(0.5)
            }
            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                if configured {
                    AssistantMessages(chat: chat, maxWidth: Self.column)
                    AssistantComposer(chat: chat)
                        .frame(maxWidth: Self.column)
                        .padding(.bottom, 8)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "key.horizontal").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("Add an API key to start").font(.headline)
                        SettingsLink { Text("Open Settings") }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        }
        .background(VisualEffect(material: .sidebar, blending: .behindWindow).ignoresSafeArea())
        .animation(.easeOut(duration: 0.18), value: listVisible)
        .onExitCommand { b.assistantExpanded = false }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            guard chat.canAttachImages else { return false }
            AssistantComposer.load(providers, into: chat)
            return true
        }
        .confirmationDialog("Delete all saved chats?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) {
                history.clear()
                chat.newChat()
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Lumen Assistant").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                BetaBadge()
                Spacer()
            }
            .padding(.top, 6)
            Button { chat.newChat() } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            TextField("Search chats", text: $query).textFieldStyle(.roundedBorder)
            if b.isPrivate {
                Text("Chats in private windows aren't saved.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if history.chats.isEmpty {
                        Text("No saved chats yet.").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ForEach(shown) { c in AssistantHistoryRow(summary: c, chat: chat) {} }
                }
            }
            if !history.chats.isEmpty {
                Button("Delete All…") { confirmClear = true }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !listVisible { Spacer().frame(width: 70) }
            IconButton(systemName: "sidebar.left", help: listVisible ? "Hide Chats" : "Show Chats") { listVisible.toggle() }
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer()
            IconButton(systemName: "arrow.down.right.and.arrow.up.left", help: "Exit Full Screen Chat") { b.assistantExpanded = false }
            IconButton(systemName: "xmark", help: "Close (⇧⌘A)") {
                b.assistantExpanded = false
                b.assistantVisible = false
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(WindowDragArea())
    }
}

/// One saved chat in a list: opens it, or deletes it.
struct AssistantHistoryRow: View {
    let summary: AssistantHistory.Summary
    var chat: AssistantChat
    var opened: () -> Void

    var body: some View {
        let current = summary.id == chat.id
        HStack(spacing: 6) {
            Button {
                chat.open(summary)
                opened()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title.isEmpty ? L("Untitled chat") : summary.title).lineLimit(1)
                    Text(summary.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            IconButton(systemName: "trash", help: "Delete Chat") {
                AssistantHistory.shared.delete(summary.id)
                if current { chat.newChat() }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(current ? Color.accentColor.opacity(0.14) : .clear))
    }
}
