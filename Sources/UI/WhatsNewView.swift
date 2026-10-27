import SwiftUI

/// "Welcome to Tacet <version>": the new features of an update, one page each with a small looping example.
/// Shown once, the first time a new version opens, to people who used an earlier one.
/// Every release adds its own pages; people coming from an older version also see the pages of the versions they skipped.
enum WhatsNew {
    struct Page: Identifiable {
        let id = UUID()
        /// The version that brought it.
        var version = "1.6.1"
        let symbol: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
        let how: [LocalizedStringKey]
        let demo: Demo
    }

    enum Demo { case rename, groups, picking, assistant, apple, reading, customize, extensions, fixes }

    /// What's new for someone who last saw the welcome of `seen` (empty when they never did).
    static func pages(since seen: String) -> [Page] {
        all.filter { seen.isEmpty || UpdateChecker.isNewer($0.version, than: seen) }
    }

    static let all: [Page] = [
        Page(version: "1.6.2", symbol: "moon.circle", title: "Lumen is now Tacet",
             text: "Same browser, new name. There were already other browsers called Lumen, and the name sounded too much like an AI product. Tacet is the mark in music for silence, where an instrument stays quiet: like the ads and trackers Tacet keeps out.",
             how: ["Your tabs, passwords, settings and extensions are all still here",
                   "The new icon is an eclipse: a dark disc in front of the sun"],
             demo: .rename),
        Page(version: "1.6.2", symbol: "wrench.and.screwdriver", title: "Small fixes",
             text: "The setup fits its window again, removing an extension also deletes what it stored, and tabs sent to a new window come back if the window doesn't open.",
             how: [], demo: .fixes),
        Page(symbol: "square.grid.3x1.folder.badge.plus", title: "Tabs that tidy themselves",
             text: "Tabs from the same site gather into a group once there are 2, 3 or 5 of them, as you choose. Groups can be saved, closed and opened again later, whole.",
             how: ["Settings › General › Tabs: when to group, and sites never to group",
                   "Right-click a group: New Tab in Group, Save and Close Group, Move Group to Window",
                   "Close duplicate tabs and sort tabs from the Tab menu or the command bar"],
             demo: .groups),
        Page(symbol: "cursorarrow.click.2", title: "Pick several tabs at once",
             text: "⌘-click or ⇧-click tabs to pick them, then group, move, pin or close them together. Drag them all at once too.",
             how: ["⌘-click adds a tab, ⇧-click picks a range", "Right-click a picked tab for everything you can do with them"],
             demo: .picking),
        Page(symbol: "sparkles", title: "Tacet Assistant does more",
             text: "It reads your other tabs, finds pages in your history and bookmarks, summarises YouTube videos from their transcript, takes screenshots, and groups tabs by topic.",
             how: ["“Compare the products in my tabs”", "“Find that SwiftUI article I read yesterday”",
                   "“Summarise this video”", "Select text and right-click › Tacet Assistant"],
             demo: .assistant),
        Page(symbol: "apple.logo", title: "Apple's model, on your Mac",
             text: "Choose Apple (on this Mac) in Settings › AI to use the assistant for free, offline, with nothing leaving your Mac. It's smaller than cloud models, so it's best for short, simple questions.",
             how: ["Needs Apple Intelligence turned on", "Use a cloud provider for long pages and hard questions"],
             demo: .apple),
        Page(symbol: "eyeglasses", title: "Read later, even offline",
             text: "In Reader, choose Save for Offline: the article and its images are kept on your Mac, ready without a connection.",
             how: ["Open Reader with ⇧⌘R, then Save for Offline at the bottom right", "Find your articles in the Library › Reading List"],
             demo: .reading),
        Page(symbol: "paintbrush", title: "Make any site yours",
             text: "Customize This Site changes a site's colours, font and width, hides pop-ups and floating bars, and hides anything you click. Changes show as you make them.",
             how: ["⋯ menu › Customize This Site…", "Pick Elements to Hide, then ↑ for a bigger block and Esc when done",
                   "Add your own CSS and JavaScript under Advanced"],
             demo: .customize),
        Page(symbol: "puzzlepiece.extension", title: "Extensions",
             text: "Add the Safari extensions that come with your apps in one click, or Chrome, Firefox and other WebExtensions from a file. They never run in private windows.",
             how: ["Settings › Extensions", "Their buttons appear next to the shield"],
             demo: .extensions),
        Page(symbol: "checkmark.seal", title: "Steadier than ever",
             text: "Every window comes back when Tacet opens, closed windows stay closed, and links from other apps open as tabs instead of empty windows.",
             how: [], demo: .fixes),
    ]
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    private let pages = WhatsNew.pages(since: Settings.shared.welcomedVersion)

    var body: some View {
        let page = pages[index]
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(String(format: L("Welcome to Tacet %@"), UpdateChecker.currentVersion))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text(page.title).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
            }
            .padding(.top, 26)

            DemoView(demo: page.demo)
                .id(page.id)
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 30).padding(.vertical, 18)
                .transition(.opacity)

            VStack(alignment: .leading, spacing: 10) {
                Text(page.text).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(page.how.enumerated()), id: \.offset) { _, line in
                    Label { Text(line).font(.callout) } icon: { Image(systemName: "arrow.right.circle.fill").foregroundStyle(.tint) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34)

            Spacer(minLength: 12)

            HStack {
                Button("Skip") { dismiss() }.buttonStyle(.link)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle().fill(i == index ? Color.accentColor : Color.primary.opacity(0.2)).frame(width: 7, height: 7)
                            .onTapGesture { withAnimation { index = i } }
                    }
                }
                Spacer()
                if index > 0 { Button("Back") { withAnimation { index -= 1 } } }
                Button(index == pages.count - 1 ? LocalizedStringKey("Start Browsing") : "Next") {
                    if index == pages.count - 1 { dismiss() } else { withAnimation { index += 1 } }
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 600, height: 600)
    }
}

/// A small looping example of a feature, drawn with plain shapes so it looks the same in every language.
private struct DemoView: View {
    let demo: WhatsNew.Demo

    var body: some View {
        TimelineView(.animation) { context in
            // A 4-second loop, eased so each step settles before the next.
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
            switch demo {
            case .rename: RenameDemo(t: t)
            case .groups: GroupsDemo(t: t)
            case .picking: PickingDemo(t: t)
            case .assistant: AssistantDemo(t: t)
            case .apple: AppleDemo(t: t)
            case .reading: ReadingDemo(t: t)
            case .customize: CustomizeDemo(t: t)
            case .extensions: ExtensionsDemo(t: t)
            case .fixes: FixesDemo(t: t)
            }
        }
    }
}

/// 0 before `a`, 1 after `b`, eased in between.
private func step(_ t: Double, _ a: Double, _ b: Double) -> Double {
    let x = min(1, max(0, (t - a) / (b - a)))
    return x * x * (3 - 2 * x)
}

private struct Chip: View {
    let color: Color
    var label: String = ""
    var width: CGFloat = 70
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.25)).frame(width: width - 30, height: 5)
        }
        .frame(width: width, height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
    }
}

/// The old name fades into the new one beside the eclipse.
private struct RenameDemo: View {
    let t: Double
    var body: some View {
        let swap = step(t, 0.3, 0.55)
        HStack(spacing: 22) {
            EclipseMark(size: 64, glow: swap)
            ZStack(alignment: .leading) {
                Text(verbatim: "Lumen").strikethrough(swap > 0.05, color: .secondary)
                    .foregroundStyle(.secondary).opacity(1 - swap).offset(y: -18 * swap)
                Text(verbatim: "Tacet").opacity(swap).offset(y: 18 * (1 - swap))
            }
            .font(.system(size: 40, weight: .bold, design: .rounded))
            .frame(width: 150, alignment: .leading)
        }
    }
}

private struct GroupsDemo: View {
    let t: Double
    var body: some View {
        let g = step(t, 0.2, 0.5)
        // Three GitHub tabs (purple) slide together into a group; the other tab moves to the end.
        ZStack {
            RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.6 * g), lineWidth: 1.5)
                .frame(width: 246, height: 38).offset(x: -70)
            Text(verbatim: "GitHub 3").font(.system(size: 11, weight: .bold)).foregroundStyle(.purple).opacity(g).offset(x: -70, y: -30)
            Chip(color: .purple).offset(x: -150)
            Chip(color: .orange).offset(x: -70 + 220 * g)
            Chip(color: .purple).offset(x: 10 - 80 * g)
            Chip(color: .purple).offset(x: 90 - 80 * g)
        }
    }
}

private struct PickingDemo: View {
    let t: Double
    var body: some View {
        let picks = [step(t, 0.1, 0.2), step(t, 0.3, 0.4), step(t, 0.5, 0.6)]
        let merge = step(t, 0.7, 0.85)
        HStack(spacing: 8 - 6 * merge) {
            ForEach(0..<4) { i in
                Chip(color: [.blue, .green, .orange, .pink][i])
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: i < 3 ? 2 * picks[i] : 0))
                    .opacity(i == 3 ? 1 - 0.5 * merge : 1)
            }
        }
        .overlay(alignment: .top) {
            Text("⌘").font(.system(size: 14, weight: .bold)).padding(6)
                .background(Circle().fill(.regularMaterial)).offset(y: -44).opacity(1 - merge)
        }
    }
}

private struct AssistantDemo: View {
    let t: Double
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Capsule().fill(Color.accentColor.opacity(0.25)).frame(width: 180, height: 22).opacity(step(t, 0.05, 0.15))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<3) { i in
                    HStack(spacing: 6) {
                        Image(systemName: ["doc.text", "clock", "play.rectangle"][i]).font(.system(size: 10)).foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.2)).frame(width: 120, height: 5)
                    }
                    .opacity(step(t, 0.2 + Double(i) * 0.12, 0.28 + Double(i) * 0.12))
                }
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.35)).frame(width: [240, 210, 150][i], height: 6)
                        .opacity(step(t, 0.6 + Double(i) * 0.08, 0.7 + Double(i) * 0.08))
                }
            }
            .frame(width: 260, alignment: .leading)
        }
    }
}

private struct AppleDemo: View {
    let t: Double
    var body: some View {
        HStack(spacing: 30) {
            Image(systemName: "laptopcomputer").font(.system(size: 64, weight: .light))
                .overlay { Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.tint).opacity(0.4 + 0.6 * abs(sin(t * .pi * 2))) }
            Image(systemName: "wifi.slash").font(.system(size: 28)).foregroundStyle(.secondary).opacity(step(t, 0.3, 0.5))
            Image(systemName: "lock.fill").font(.system(size: 28)).foregroundStyle(.green).opacity(step(t, 0.5, 0.7))
        }
    }
}

private struct ReadingDemo: View {
    let t: Double
    var body: some View {
        let save = step(t, 0.3, 0.55)
        HStack(spacing: 40) {
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.5)).frame(width: 90, height: 8)
                RoundedRectangle(cornerRadius: 4).fill(Color.teal.opacity(0.5)).frame(width: 110, height: 40)
                ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.2)).frame(width: 110, height: 5) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .scaleEffect(1 - 0.5 * save).opacity(1 - 0.6 * save)
            .offset(x: 70 * save)
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 26)).foregroundStyle(.tint)
                HStack(spacing: 6) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.35)).frame(width: 80, height: 6)
                }
                .opacity(step(t, 0.55, 0.7))
            }
        }
    }
}

private struct CustomizeDemo: View {
    let t: Double
    var body: some View {
        let hide = step(t, 0.25, 0.4)
        let dark = step(t, 0.55, 0.75)
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.6)).frame(width: 220, height: 18 * (1 - hide))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2).opacity(step(t, 0.1, 0.2) * (1 - hide)))
                .opacity(1 - hide)
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 2).fill((dark > 0.5 ? Color.white : Color.black).opacity(0.35)).frame(width: [220, 200, 210, 140][i], height: 6)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 1 - 0.85 * dark)))
    }
}

private struct ExtensionsDemo: View {
    let t: Double
    var body: some View {
        let slide = step(t, 0.15, 0.4)
        let count = Int(step(t, 0.5, 0.9) * 12)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)).frame(width: 200, height: 26)
            ZStack(alignment: .topTrailing) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 18)).foregroundStyle(.red)
                if count > 0 {
                    Text("\(count)").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).background(Capsule().fill(.red)).offset(x: 8, y: -6)
                }
            }
            .offset(y: -60 * (1 - slide)).opacity(slide)
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 18)).foregroundStyle(.tint)
        }
    }
}

private struct FixesDemo: View {
    let t: Double
    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<3) { i in
                Image(systemName: "macwindow").font(.system(size: 40, weight: .light))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
                            .opacity(step(t, 0.2 + Double(i) * 0.15, 0.3 + Double(i) * 0.15))
                    }
            }
        }
    }
}
