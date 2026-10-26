import SwiftUI

/// "New update available": version, what's new, a link to the release and an install button.
struct UpdateView: View {
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var installer = UpdateInstaller.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let r = updates.available {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New Update Available").font(.title2.weight(.bold))
                        Text(String(format: L("%@ is ready. You have Lumen %@."), r.name, UpdateChecker.currentVersion))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("What's new").font(.headline)
                ScrollView {
                    Text(notes(r.notes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(height: 220)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                Link(destination: r.page) {
                    Label("View release on GitHub", systemImage: "arrow.up.right.square")
                }
                switch installer.state {
                case .downloading(let p):
                    ProgressView(value: p) { Text("Downloading…").font(.caption) }
                case .installing:
                    ProgressView { Text("Installing… Lumen will restart.").font(.caption) }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                case .idle:
                    EmptyView()
                }
                HStack {
                    Button("Skip This Version") {
                        updates.skip(r)
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(r.asset == nil ? "Download" : "Install Update") { installer.install(r) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
            }
            .padding(24)
            .frame(width: 520)
            .tint(Settings.shared.accent)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                Text(updates.lastResult ?? L("Lumen is up to date."))
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(30)
            .frame(width: 320)
        }
    }

    private var busy: Bool {
        switch installer.state {
        case .downloading, .installing: true
        default: false
        }
    }

    private func notes(_ markdown: String) -> AttributedString {
        let text = markdown.isEmpty ? L("No release notes.") : markdown
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
