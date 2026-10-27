import SwiftUI
import UniformTypeIdentifiers

/// The assistant chat, in a panel on the right of the window.
struct AssistantPanel: View {
    @Environment(BrowserState.self) var b
    @Bindable var s = Settings.shared

    private var chat: AssistantChat { b.assistant }
    private var configured: Bool { !s.aiProvider.needsKey || AIKeys.has(s.aiProvider) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if configured {
                AssistantMessages(chat: chat)
                AssistantComposer(chat: chat)
            } else {
                setup
            }
        }
        .frame(width: 380)
        .background(VisualEffect(material: .sidebar, blending: .withinWindow))
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            guard chat.canAttachImages else { return false }
            AssistantComposer.load(providers, into: chat)
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("Lumen Assistant").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
            BetaBadge()
            ChatModelMenu(chat: chat)
            Spacer(minLength: 4)
            IconButton(systemName: "square.and.pencil", help: "New Chat") { chat.newChat() }
                .disabled(chat.messages.isEmpty && chat.draft.isEmpty)
            IconButton(systemName: "xmark", help: "Close (⇧⌘A)") { b.assistantVisible = false }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(WindowDragArea())
    }

    private var setup: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.horizontal").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Add an API key to start").font(.headline)
            Text("Lumen Assistant uses your own key from Anthropic, OpenAI, OpenRouter, DeepSeek or any OpenAI-compatible server. The key stays in your Keychain.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SettingsLink { Text("Open Settings") }
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Messages

struct AssistantMessages: View {
    var chat: AssistantChat
    @Environment(BrowserState.self) var b

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty { AssistantSuggestions(chat: chat) }
                    ForEach(chat.messages) { m in
                        AssistantBubble(message: m, thinking: chat.busy && m.id == chat.messages.last?.id)
                            .id(m.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }
}

struct AssistantSuggestions: View {
    var chat: AssistantChat

    private var prompts: [String] {
        chat.pageToAttach != nil
            ? ["Summarise this page", "What are the key points?", "Explain the text I selected"]
            : ["What can you do?", "Explain the text I selected"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about the page you're reading, or anything else.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(prompts, id: \.self) { p in
                Button {
                    chat.draft = L(p)
                    chat.send()
                } label: {
                    Text(LocalizedStringKey(p)).font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}

struct AssistantBubble: View {
    let message: AssistantChat.Message
    let thinking: Bool
    @Environment(BrowserState.self) var b

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if let page = message.pageTitle {
                        Label(page, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !message.images.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(message.images.enumerated()), id: \.offset) { _, img in
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text).textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.18)))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.activity.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
                }
                if !message.text.isEmpty {
                    Text(Self.markdown(message.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if thinking && message.error == nil {
                    ProgressView().controlSize(.small)
                }
                ForEach(Array(message.links.enumerated()), id: \.offset) { _, link in
                    Button { b.newTab(url: link.url) } label: {
                        Label(link.title, systemImage: "arrow.up.right.square").lineLimit(1)
                    }
                    .help(link.url.absoluteString)
                }
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
            }
        }
    }

    /// Inline Markdown (bold, italics, code, links), keeping the model's line breaks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Composer

struct AssistantComposer: View {
    @Bindable var chat: AssistantChat
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if chat.pageToAttach != nil || !chat.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let page = chat.pageToAttach {
                            chip(title: page.title, icon: page.favicon) { chat.removePageAttachment() }
                        }
                        ForEach(chat.images) { img in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: img.image).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                                Button { chat.images.removeAll { $0.id == img.id } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                if chat.canAttachImages {
                    IconButton(systemName: "photo.badge.plus", help: "Attach Image") { pickImages() }
                }
                TextField(L("Ask Lumen Assistant…"), text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        chat.send()
                        return .handled
                    }
                    .padding(.vertical, 5)
                if chat.busy {
                    IconButton(systemName: "stop.circle.fill", help: "Stop", tint: .accentColor, size: 16) { chat.stop() }
                } else {
                    IconButton(systemName: "arrow.up.circle.fill", help: "Send", tint: .accentColor, size: 16) { chat.send() }
                        .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.images.isEmpty)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            Text("Answers come from your AI provider and can be wrong.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .onAppear { focused = true }
    }

    private func chip(title: String, icon: NSImage?, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 12, height: 12) } else { Image(systemName: "doc.text").font(.caption) }
            Text(title).font(.caption).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Don't attach this page")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .help("This page is sent with your next message")
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let img = NSImage(contentsOf: url) { chat.addImage(img) } }
    }

    static func load(_ providers: [NSItemProvider], into chat: AssistantChat) {
        for p in providers {
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage { DispatchQueue.main.async { chat.addImage(img) } }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, let img = NSImage(contentsOf: url) { DispatchQueue.main.async { chat.addImage(img) } }
                }
            }
        }
    }
}

/// The model for this chat, from the provider's list.
struct ChatModelMenu: View {
    var chat: AssistantChat
    private var models = AIModels.shared
    private var s = Settings.shared

    init(chat: AssistantChat) { self.chat = chat }

    var body: some View {
        let list = models.models(for: s.aiProvider)
        let current = list.first { $0.id == chat.model }?.name ?? chat.model
        Menu {
            ForEach(list) { m in
                Button { chat.model = m.id } label: {
                    if m.id == chat.model { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                }
            }
            if list.isEmpty { Text(models.loading.contains(s.aiProvider) ? "Loading models…" : "No models loaded") }
            Divider()
            Button("Refresh List") { models.refresh(s.aiProvider, force: true) }
        } label: {
            Text(current).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 150)
        .help("Model for this chat")
        .onAppear { models.refresh(s.aiProvider) }
    }
}

struct BetaBadge: View {
    var body: some View {
        Text("Beta").font(.system(size: 9.5, weight: .bold)).textCase(.uppercase)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(.tint)
    }
}

/// Opens and closes the assistant panel; shown only when the assistant is turned on.
struct AssistantButton: View {
    @Environment(BrowserState.self) var b
    private var s = Settings.shared

    var body: some View {
        if s.aiEnabled {
            IconButton(systemName: "sparkles", help: "Lumen Assistant (⇧⌘A)", tint: b.assistantVisible ? .accentColor : nil) {
                b.assistantVisible.toggle()
            }
        }
    }
}

// MARK: - Introduction

/// Shown once to people who used Lumen before the assistant existed.
struct AssistantIntro: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 62, height: 62)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("New: Lumen Assistant").font(.system(size: 22, weight: .bold))
                    BetaBadge()
                }
                Text("An AI assistant in a panel beside the page, for questions about what you're reading.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 10) {
                feature("doc.text.magnifyingglass", "Summaries and answers about the page you have open")
                feature("photo", "Images too, with models that can read them")
                feature("key", "Your own key: Anthropic, OpenAI, OpenRouter, DeepSeek, or a model on your Mac with Ollama")
                feature("hand.raised", "Off until you turn it on. Nothing is sent until you ask something")
            }
            .frame(maxWidth: 420, alignment: .leading)
            HStack(spacing: 10) {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Turn On…") {
                    Settings.shared.aiEnabled = true
                    dismiss()
                    openSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            Text("You can change this anytime in Settings › AI.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(width: 500)
    }

    private func feature(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings

struct AIPane: View {
    @Bindable private var s = Settings.shared
    @State private var key = ""
    @State private var saved = false

    private var modelBinding: Binding<String> {
        Binding(get: { s.aiModelName },
                set: { var m = s.aiModels; m[s.aiProvider.rawValue] = $0; s.aiModels = m })
    }

    private var visionBinding: Binding<Bool> {
        Binding(get: { s.aiProvider.supportsImages(s.aiModelName) },
                set: { var v = s.aiVision; v[s.aiProvider.visionKey(s.aiModelName)] = $0; s.aiVision = v })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $s.aiEnabled) {
                    HStack(spacing: 6) { Text("Turn on Lumen Assistant"); BetaBadge() }
                }
                Text("Lumen Assistant answers questions about the page you're reading in a panel on the right (⇧⌘A). It is off unless you turn it on, and nothing is sent until you ask something.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider") {
                Picker("Provider", selection: $s.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.name).tag($0) }
                }
                if s.aiProvider == .custom {
                    LabeledContent("Server address") {
                        TextField("", text: $s.aiBaseURL, prompt: Text(AIProvider.custom.defaultBaseURL))
                            .textFieldStyle(.roundedBorder).frame(minWidth: 260)
                            .onSubmit { AIModels.shared.refresh(.custom, force: true) }
                    }
                    Text("Any server that speaks the OpenAI Chat Completions API, such as Ollama or LM Studio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent(s.aiProvider.needsKey ? "API key" : "API key (optional)") {
                    HStack {
                        SecureField("", text: $key, prompt: Text("Paste your key here"))
                            .textFieldStyle(.roundedBorder).frame(minWidth: 240)
                            .onSubmit(saveKey)
                        Button(saved ? "Saved" : "Save", action: saveKey).disabled(saved)
                    }
                }
                LabeledContent("Default model") {
                    ModelPicker(provider: s.aiProvider, selection: modelBinding)
                }
                if let error = AIModels.shared.errors[s.aiProvider] {
                    Text(String(format: L("Couldn't load the models: %@"), error)).font(.caption).foregroundStyle(.orange)
                }
                Toggle("This model can read images", isOn: visionBinding)
            }
            Section("Privacy") {
                Text("When you ask something, your message, the attached page and any images are sent to the provider you chose, under their privacy terms. With a server on your own Mac, such as Ollama, nothing leaves your computer. Your API key is kept in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadKey()
            AIModels.shared.refresh(s.aiProvider)
        }
        .onChange(of: s.aiProvider) { _, p in
            loadKey()
            AIModels.shared.refresh(p)
        }
        .onChange(of: key) { _, _ in saved = false }
    }

    private func loadKey() {
        key = AIKeys.get(s.aiProvider) ?? ""
        saved = true
    }

    private func saveKey() {
        AIKeys.set(key, for: s.aiProvider)
        saved = true
        AIModels.shared.refresh(s.aiProvider, force: true)
    }
}

/// Chooses one of the provider's models from its own list, or takes a typed name when the list can't be loaded.
struct ModelPicker: View {
    let provider: AIProvider
    @Binding var selection: String
    private var models = AIModels.shared

    init(provider: AIProvider, selection: Binding<String>) {
        self.provider = provider
        _selection = selection
    }

    var body: some View {
        let list = models.models(for: provider)
        HStack(spacing: 6) {
            if list.isEmpty {
                if models.loading.contains(provider) {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").foregroundStyle(.secondary)
                } else {
                    TextField("", text: $selection, prompt: Text("Type a model name"))
                        .textFieldStyle(.roundedBorder).frame(minWidth: 200)
                }
            } else {
                Picker("", selection: $selection) {
                    if !list.contains(where: { $0.id == selection }) { Text(selection).tag(selection) }
                    ForEach(list) { m in Text(m.name).tag(m.id) }
                }
                .labelsHidden()
                .frame(minWidth: 200)
            }
            Button { models.refresh(provider, force: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh List")
                .disabled(models.loading.contains(provider))
        }
    }
}
