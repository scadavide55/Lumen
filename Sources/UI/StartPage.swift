import AVFoundation
import SwiftUI

struct StartPage: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var b: BrowserState
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var bookmarks = Bookmarks.shared
    @ObservedObject private var blocker = ContentBlocker.shared

    private var light: Bool { s.startBackground == .plain }

    var body: some View {
        ZStack {
            StartBackgroundView(style: s.startBackground, isPrivate: b.isPrivate)
            VStack(spacing: 24) {
                Spacer(minLength: 40)
                if s.showClock {
                    TimelineView(.everyMinute) { ctx in
                        Text(ctx.date, format: .dateTime.hour().minute())
                            .font(.system(size: 78, weight: .thin, design: .rounded))
                            .monospacedDigit()
                    }
                }
                if b.isPrivate {
                    VStack(spacing: 6) {
                        Label("Private browsing", systemImage: "eyeglasses").font(.system(size: 20, weight: .semibold))
                        Text("Lumen forgets the history, cookies and site data of this window when you close it.")
                            .font(.system(size: 13)).opacity(0.75)
                    }
                } else if s.showGreeting {
                    Text(greeting).font(.system(size: 20, weight: .medium)).opacity(0.9)
                }
                SearchPill(engine: s.engine.name, light: light) { b.showPalette("") }
                if s.showFavorites && !bookmarks.items.isEmpty {
                    FavoritesGrid(items: Array(bookmarks.items.prefix(12)), light: light) { tab.load($0) }
                }
                Spacer(minLength: 40)
                HStack(spacing: 6) {
                    Image(systemName: s.adBlock ? "shield.lefthalf.filled" : "shield.slash")
                    Text(s.adBlock ? LocalizedStringKey("Lumen Shield is blocking ads and trackers · \(blocker.ruleCount.formatted()) rules") : "Lumen Shield is off")
                }
                .font(.system(size: 11.5))
                .opacity(0.65)
                .padding(.bottom, 18)
            }
            .foregroundStyle(light ? Color.primary : Color.white)
            .padding(.horizontal, 40)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let base = L(h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : h < 22 ? "Good evening" : "Good night")
        let name = s.userName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? base : "\(base), \(name)"
    }
}

struct SearchPill: View {
    let engine: String
    let light: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                Text("Search with \(engine) or enter an address").font(.system(size: 15))
                Spacer()
                Text("⌘L").font(.system(size: 11, weight: .medium, design: .rounded)).opacity(0.6)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: 560, minHeight: 48)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(light ? AnyShapeStyle(Color.primary.opacity(hover ? 0.09 : 0.06)) : AnyShapeStyle(.ultraThinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(light ? 0 : 0.18)))
            }
            .scaleEffect(hover ? 1.01 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct FavoritesGrid: View {
    let items: [Bookmark]
    let light: Bool
    let open: (URL) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 100), spacing: 14)], spacing: 14) {
            ForEach(items) { bm in
                FavoriteTile(bookmark: bm, light: light) { open(bm.url) }
            }
        }
        .frame(maxWidth: 600)
    }
}

struct FavoriteTile: View {
    let bookmark: Bookmark
    let light: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(light ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.ultraThinMaterial))
                    if let icon = Favicons.shared.cached(bookmark.url.host) {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Text(String(InputResolver.displayHost(bookmark.url).prefix(1)).uppercased())
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                    }
                }
                .frame(width: 60, height: 60)
                .scaleEffect(hover ? 1.06 : 1)
                Text(bookmark.title).font(.system(size: 11)).lineLimit(1).opacity(0.85)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .contextMenu {
            Button("Remove from Favorites") { Bookmarks.shared.remove([bookmark.id]) }
        }
        .help(bookmark.url.absoluteString)
    }
}

struct StartBackgroundView: View {
    let style: StartBackground
    let isPrivate: Bool
    @ObservedObject private var s = Settings.shared

    var body: some View {
        if isPrivate {
            AnimatedGradient(base: [0x1A1033, 0x2E1A57], blobs: [0x7B4DDB, 0x3B2A8C], animated: s.animateBackground)
        } else {
            switch style {
            case .image:
                if let img = NSImage(contentsOfFile: s.startImagePath) {
                    GeometryReader { g in
                        Image(nsImage: img).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                            .overlay(Color.black.opacity(0.25))
                    }
                } else {
                    Self.fallback
                }
            case .video:
                if FileManager.default.fileExists(atPath: s.startVideoPath) {
                    VideoBackground(url: URL(fileURLWithPath: s.startVideoPath)).overlay(Color.black.opacity(0.25))
                } else {
                    Self.fallback
                }
            case .plain:
                Color(nsColor: .textBackgroundColor)
            case .accent:
                LinearGradient(colors: [s.accent, s.accent.opacity(0.55), .black.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .flow:
                FlowGradient()
            default:
                let p = Self.presets[style] ?? Self.presets[.aurora]!
                AnimatedGradient(base: p.0, blobs: p.1, animated: s.animateBackground)
            }
        }
    }

    static let presets: [StartBackground: ([UInt32], [UInt32])] = [
        .aurora: ([0x0B1026, 0x1B2A6B], [0x2EC4B6, 0x8E44AD]),
        .dusk: ([0x2B1B3F, 0x7A2E58], [0xFF8A5B, 0xFFC371]),
        .ocean: ([0x03152B, 0x0B3D6E], [0x00B4D8, 0x48CAE4]),
        .forest: ([0x0B2016, 0x1E4D3A], [0x52B788, 0x95D5B2]),
        .ember: ([0x2A0E0E, 0x6B1E1E], [0xFF6B35, 0xFFB347]),
        .graphite: ([0x1C1C1E, 0x3A3A3C], [0x636366, 0x8E8E93]),
    ]

    private static var fallback: some View {
        AnimatedGradient(base: [0x0B1026, 0x1B2A6B], blobs: [0x2EC4B6, 0x8E44AD], animated: false)
    }

    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A preset gradient whose two glows can drift slowly around the page.
struct AnimatedGradient: View {
    let base: [UInt32]
    let blobs: [UInt32]
    let animated: Bool

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in layers(ctx.date.timeIntervalSinceReferenceDate) }
        } else {
            layers(nil)
        }
    }

    private func layers(_ t: Double?) -> some View {
        let a = t.map { UnitPoint(x: 0.2 + 0.18 * sin($0 / 6), y: 0.15 + 0.15 * cos($0 / 8)) } ?? UnitPoint(x: 0.15, y: 0.1)
        let b = t.map { UnitPoint(x: 0.8 + 0.15 * cos($0 / 7), y: 0.85 + 0.12 * sin($0 / 5)) } ?? UnitPoint(x: 0.9, y: 0.95)
        return GeometryReader { g in
            let d = max(g.size.width, g.size.height)
            ZStack {
                LinearGradient(colors: base.map(StartBackgroundView.color), startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [StartBackgroundView.color(blobs[0]).opacity(0.55), .clear], center: a, startRadius: 0, endRadius: d * 0.6)
                RadialGradient(colors: [StartBackgroundView.color(blobs[1]).opacity(0.45), .clear], center: b, startRadius: 0, endRadius: d * 0.65)
            }
        }
    }
}

/// Colours that slowly shift around the hue wheel.
struct FlowGradient: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let h = (t / 60).truncatingRemainder(dividingBy: 1)
            GeometryReader { g in
                let d = max(g.size.width, g.size.height)
                ZStack {
                    LinearGradient(colors: [hue(h, 0.55, 0.28), hue(h + 0.12, 0.6, 0.42)],
                                   startPoint: UnitPoint(x: 0.5 + 0.5 * cos(t / 9), y: 0), endPoint: UnitPoint(x: 0.5 - 0.5 * cos(t / 9), y: 1))
                    RadialGradient(colors: [hue(h + 0.3, 0.7, 0.75).opacity(0.5), .clear],
                                   center: UnitPoint(x: 0.3 + 0.25 * sin(t / 7), y: 0.3 + 0.2 * cos(t / 11)), startRadius: 0, endRadius: d * 0.55)
                    RadialGradient(colors: [hue(h + 0.55, 0.7, 0.7).opacity(0.45), .clear],
                                   center: UnitPoint(x: 0.75 + 0.2 * cos(t / 8), y: 0.75 + 0.2 * sin(t / 10)), startRadius: 0, endRadius: d * 0.6)
                }
            }
        }
    }

    private func hue(_ h: Double, _ s: Double, _ b: Double) -> Color {
        Color(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b)
    }
}

/// A muted, looping video.
struct VideoBackground: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PlayerView { PlayerView(url: url) }
    func updateNSView(_ v: PlayerView, context: Context) { v.play(url) }
    static func dismantleNSView(_ v: PlayerView, coordinator: ()) { v.stop() }

    final class PlayerView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var current: URL?

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            play(url)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func play(_ url: URL) {
            guard url != current else { return }
            current = url
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.play()
        }

        func stop() {
            player.pause()
            looper = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? player.pause() : player.play()
        }
    }
}
