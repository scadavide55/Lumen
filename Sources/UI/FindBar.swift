import SwiftUI

extension Notification.Name {
    /// ⌘G / ⇧⌘G from the menu. `object` is true when searching backwards.
    static let findAgain = Notification.Name("lumen.findAgain")
}

struct FindBar: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var b: BrowserState
    @State private var text = ""
    @State private var found = true
    @FocusState private var focused: Bool
    private static var lastQuery = ""

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary).padding(.leading, 8)
            TextField("Find on page", text: $text)
                .textFieldStyle(.plain)
                .frame(width: 190)
                .focused($focused)
                .onKeyPress(keys: [.return]) { press in
                    search(backwards: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.escape) { close(); return .handled }
                .onExitCommand { close() }
            if !found && !text.isEmpty {
                Text("Not found").font(.system(size: 11)).foregroundStyle(.red)
            }
            IconButton(systemName: "chevron.up", help: "Previous (⇧⌘G)", size: 11) { search(backwards: true) }
            IconButton(systemName: "chevron.down", help: "Next (⌘G)", size: 11) { search(backwards: false) }
            IconButton(systemName: "xmark", help: "Done", size: 11) { close() }
        }
        .frame(height: 36)
        .padding(.trailing, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .padding(10)
        .onAppear {
            text = Self.lastQuery
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: text) { _, _ in search(backwards: false) }
        .onReceive(NotificationCenter.default.publisher(for: .findAgain)) { note in
            search(backwards: note.object as? Bool ?? false)
        }
    }

    private func search(backwards: Bool) {
        Self.lastQuery = text
        guard !text.isEmpty else { found = true; return }
        tab.find(text, backwards: backwards) { found = $0 }
    }

    private func close() {
        b.findVisible = false
        tab.webView?.window?.makeFirstResponder(tab.webView)
    }
}
