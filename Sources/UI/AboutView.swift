import SwiftUI
import WebKit

struct AboutView: View {
    private var blocker = ContentBlocker.shared
    private var updates = UpdateChecker.shared
    private var passwords = PasswordStore.shared
    private var history = History.shared
    private var bookmarks = Bookmarks.shared
    @Environment(\.openWindow) private var openWindow
    @State private var appeared = false

    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    private var webKit: String {
        let v = Bundle(identifier: "com.apple.WebKit")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v ?? "–"
    }
    private var openTabs: Int { WindowRegistry.shared.browsers.reduce(0) { $0 + $1.tabs.count } }

    var body: some View {
        VStack(spacing: 0) {
            hero
                .padding(.top, 34)
            stats
                .padding(.top, 26)
            links
                .padding(.top, 22)
            Spacer(minLength: 16)
            footer
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 28)
        .foregroundStyle(.white)
        .frame(width: 520, height: 560)
        .background {
            ZStack {
                FlowGradient().opacity(0.9)
                Color.black.opacity(0.35)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { appeared = true }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.84, blue: 0.54).opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 90))
                    .frame(width: 180, height: 180)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 110, height: 110)
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                    .scaleEffect(appeared ? 1 : 0.8)
                    .rotationEffect(.degrees(appeared ? 0 : -8))
            }
            .frame(height: 140)
            HStack(spacing: 8) {
                Text("Lumen").font(.system(size: 34, weight: .bold, design: .rounded))
                Text("BETA").font(.system(size: 10, weight: .heavy)).tracking(1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.white.opacity(0.2), in: Capsule())
            }
            Text("The quiet browser for your Mac").font(.system(size: 14)).opacity(0.8)
            Text(String(format: L("Version %@ (%@)"), UpdateChecker.currentVersion, build))
                .font(.system(size: 12, weight: .medium, design: .monospaced)).opacity(0.7)
                .textSelection(.enabled)
            if let r = updates.available {
                Button { openWindow(id: "update") } label: {
                    Label(String(format: L("%@ is available."), r.name), systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Color.white.opacity(0.22), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .offset(y: appeared ? 0 : 12)
        .opacity(appeared ? 1 : 0)
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            stat(blocker.ruleCount.formatted(), "Shield rules", "shield.lefthalf.filled")
            stat("\(openTabs)", "Open tabs", "square.on.square")
            stat("\(passwords.logins.count)", "Passwords", "key.fill")
            stat(history.entries.count.formatted(), "History items", "clock")
            stat("\(bookmarks.items.count)", "Bookmarks", "star.fill")
            stat("WebKit \(webKit)", "Engine", "gearshape.2")
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.6).delay(0.15), value: appeared)
    }

    private func stat(_ value: String, _ label: LocalizedStringKey, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13)).opacity(0.75)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10.5)).opacity(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12)))
    }

    private var links: some View {
        HStack(spacing: 10) {
            linkButton("Website", "globe") { NSWorkspace.shared.open(URL(string: "https://scadavide55.github.io/Lumen/")!) }
            linkButton("GitHub", "chevron.left.forwardslash.chevron.right") { NSWorkspace.shared.open(URL(string: "https://github.com/scadavide55/Lumen")!) }
            linkButton("Release Notes", "doc.text") { NSWorkspace.shared.open(URL(string: "https://github.com/scadavide55/Lumen/releases")!) }
            linkButton("Updates", "arrow.triangle.2.circlepath") { updates.check(force: true) { openWindow(id: "update") } }
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.6).delay(0.3), value: appeared)
    }

    private func linkButton(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("No accounts, no analytics, no tracking.").font(.system(size: 11.5, weight: .medium))
            Text("© 2026 Lumen · Made with Swift, SwiftUI and WebKit").font(.system(size: 10.5)).opacity(0.65)
            Text("Free software under the GNU GPL v3").font(.system(size: 10.5)).opacity(0.65)
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.6).delay(0.45), value: appeared)
    }
}
