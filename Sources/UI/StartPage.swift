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
            StartBackgroundView(style: s.startBackground, imagePath: s.startImagePath, accent: s.accent, isPrivate: b.isPrivate)
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
                    Text(s.adBlock ? "Lumen Shield is blocking ads and trackers · \(blocker.ruleCount.formatted()) rules" : "Lumen Shield is off")
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
        let base = h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : h < 22 ? "Good evening" : "Good night"
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
    let imagePath: String
    let accent: Color
    let isPrivate: Bool

    var body: some View {
        if isPrivate {
            Self.gradient(base: [0x1A1033, 0x2E1A57], blobs: [0x7B4DDB, 0x3B2A8C])
        } else {
            switch style {
            case .image:
                if let img = NSImage(contentsOfFile: imagePath) {
                    GeometryReader { g in
                        Image(nsImage: img).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                            .overlay(Color.black.opacity(0.25))
                    }
                } else {
                    Self.gradient(base: [0x0B1026, 0x1B2A6B], blobs: [0x2EC4B6, 0x8E44AD])
                }
            case .plain:
                Color(nsColor: .textBackgroundColor)
            case .accent:
                LinearGradient(colors: [accent, accent.opacity(0.55), .black.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .aurora: Self.gradient(base: [0x0B1026, 0x1B2A6B], blobs: [0x2EC4B6, 0x8E44AD])
            case .dusk: Self.gradient(base: [0x2B1B3F, 0x7A2E58], blobs: [0xFF8A5B, 0xFFC371])
            case .ocean: Self.gradient(base: [0x03152B, 0x0B3D6E], blobs: [0x00B4D8, 0x48CAE4])
            case .forest: Self.gradient(base: [0x0B2016, 0x1E4D3A], blobs: [0x52B788, 0x95D5B2])
            case .ember: Self.gradient(base: [0x2A0E0E, 0x6B1E1E], blobs: [0xFF6B35, 0xFFB347])
            case .graphite: Self.gradient(base: [0x1C1C1E, 0x3A3A3C], blobs: [0x636366, 0x8E8E93])
            }
        }
    }

    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func gradient(base: [UInt32], blobs: [UInt32]) -> some View {
        GeometryReader { g in
            let d = max(g.size.width, g.size.height)
            ZStack {
                LinearGradient(colors: base.map(color), startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [color(blobs[0]).opacity(0.55), .clear], center: UnitPoint(x: 0.15, y: 0.1),
                               startRadius: 0, endRadius: d * 0.6)
                RadialGradient(colors: [color(blobs[1]).opacity(0.45), .clear], center: UnitPoint(x: 0.9, y: 0.95),
                               startRadius: 0, endRadius: d * 0.65)
            }
        }
    }
}
