import SwiftUI
import UniformTypeIdentifiers

/// Thumbnails of every start page background, plus your own photo or video.
struct BackgroundPicker: View {
    @Bindable private var s = Settings.shared
    @State private var error: String?
    @State private var importing = false

    private let builtIn: [StartBackground] = [.aurora, .dusk, .ocean, .forest, .ember, .graphite, .flow, .accent, .plain]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                ForEach(builtIn) { bg in
                    tile(bg.label, selected: s.startBackground == bg) { s.startBackground = bg } preview: {
                        StartBackgroundView(style: bg, isPrivate: false)
                    }
                }
                tile(L("Photo…"), selected: s.startBackground == .image, action: choosePhoto) {
                    if s.startBackground == .image || !s.startImagePath.isEmpty {
                        StartBackgroundView(style: .image, isPrivate: false)
                    } else {
                        placeholder("photo")
                    }
                }
                tile(L("Video…"), selected: s.startBackground == .video, action: chooseVideo) {
                    if !s.startVideoPath.isEmpty && FileManager.default.fileExists(atPath: s.startVideoPath) {
                        StartBackgroundView(style: .video, isPrivate: false)
                    } else {
                        placeholder("film")
                    }
                }
            }
            Toggle("Animate gradient backgrounds", isOn: $s.animateBackground)
                .disabled(!s.startBackground.isGradient)
            HStack(spacing: 8) {
                if importing { ProgressView().controlSize(.small) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Text("Videos: MP4, MOV or M4V, up to 60 seconds and 300 MB. They play muted, on a loop.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private func tile<P: View>(_ title: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder preview: () -> P) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                preview()
                    .frame(height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1))
                Text(title).font(.system(size: 11)).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func placeholder(_ symbol: String) -> some View {
        ZStack {
            Color.primary.opacity(0.06)
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.secondary)
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = BackgroundMedia.imageTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch BackgroundMedia.importImage(url) {
        case .success(let path):
            s.startImagePath = path
            s.startBackground = .image
            error = nil
        case .failure(let e):
            error = e.localizedDescription
        }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = BackgroundMedia.videoTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        BackgroundMedia.importVideo(url) { result in
            importing = false
            switch result {
            case .success(let path):
                s.startVideoPath = path
                s.startBackground = .video
                error = nil
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }
}

/// Visual choice between the sidebar, separate top tabs and compact top tabs.
struct TabLayoutPicker: View {
    @Bindable private var s = Settings.shared

    var body: some View {
        HStack(spacing: 14) {
            option(.vertical, "Sidebar") { LayoutSketch(layout: .vertical) }
            option(.horizontal, "Separate") { LayoutSketch(layout: .horizontal) }
            option(.compact, "Compact") { LayoutSketch(layout: .compact) }
        }
    }

    private func option<P: View>(_ layout: TabLayout, _ title: LocalizedStringKey, @ViewBuilder preview: () -> P) -> some View {
        let selected = s.tabLayout == layout
        return Button { s.tabLayout = layout } label: {
            VStack(spacing: 6) {
                preview()
                    .frame(width: 128, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1))
                Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small drawing of a Lumen window in each tab layout, over the Dusk background like Safari's previews.
struct LayoutSketch: View {
    let layout: TabLayout

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            StartBackgroundView(style: .dusk, isPrivate: false)
            window.frame(width: 104, height: 62).offset(x: 6, y: 6)
        }
    }

    private var lights: some View {
        HStack(spacing: 2.5) {
            Circle().fill(Color.red).frame(width: 4.5)
            Circle().fill(Color.yellow).frame(width: 4.5)
            Circle().fill(Color.green).frame(width: 4.5)
        }
    }

    @ViewBuilder private var window: some View {
        let chrome = Color(white: 0.18)
        let bar = Color(white: 0.32)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.08))
            switch layout {
            case .vertical:
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        lights
                        RoundedRectangle(cornerRadius: 2).fill(bar).frame(height: 5)
                        ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 2).fill(bar.opacity(0.6)).frame(height: 4) }
                    }
                    .padding(5)
                    .frame(width: 34)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(chrome)
                    Spacer()
                }
            case .horizontal:
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) { lights; Capsule().fill(bar).frame(width: 12, height: 5); Capsule().fill(bar).frame(height: 5) }
                    Capsule().fill(bar.opacity(0.7)).frame(width: 40, height: 4)
                }
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(chrome)
            case .compact:
                HStack(spacing: 4) {
                    lights
                    Capsule().fill(bar).frame(width: 12, height: 5)
                    Capsule().fill(bar.opacity(0.95)).frame(height: 6)
                }
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(chrome)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
