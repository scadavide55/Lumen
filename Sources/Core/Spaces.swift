import SwiftUI

/// A Space: a whole working set — tabs, pinned tabs, groups, the split view and the tab you were on — with a note to
/// yourself, that a window leaves and comes back to in one step. "School" and "Coding" swap everything at once
/// instead of needing a window each.
///
/// A Space open in a window lives in that window; `saved` is how it was left, and is what comes back when you switch
/// to it. Pages reload when you open them, as after a restart: sites' own state isn't kept.
struct Space: Codable, Identifiable {
    var id = UUID()
    var name: String
    var symbol = "square.stack"
    var color = 0
    /// A line to yourself, such as where to pick up.
    var note = ""
    /// The profile it belongs to (nil: the main one). Its tabs only ever open in that profile's windows, so sign-ins
    /// and site data never cross profiles.
    var profile: UUID?
    var saved: WindowSnapshot?

    var tint: Color { TabGroup.colors[color % TabGroup.colors.count] }

    static let symbols = ["square.stack", "graduationcap", "chevron.left.forwardslash.chevron.right", "briefcase", "house",
                          "book", "paintpalette", "cart", "airplane", "music.note", "gamecontroller", "heart"]
}

@Observable
final class Spaces {
    static let shared = Spaces()

    private(set) var items: [Space] = []
    @ObservationIgnored private let file = StoredFile<[Space]>("spaces.plist", format: .binaryPlist)

    private init() {
        items = file.load() ?? []
    }

    func space(_ id: UUID?) -> Space? { id.flatMap { id in items.first { $0.id == id } } }

    /// The Spaces of one profile, in order.
    func items(for profile: UUID?) -> [Space] { items.filter { $0.profile == profile } }

    @discardableResult
    func add(_ name: String, profile: UUID?) -> Space {
        let n = items(for: profile).count
        let space = Space(name: name, symbol: Space.symbols[n % Space.symbols.count], color: n, profile: profile)
        items.append(space)
        persist()
        return space
    }

    func update(_ id: UUID, _ change: (inout Space) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        persist()
    }

    /// Removes a Space and its saved tabs. Windows showing it are left out of Spaces first (BrowserState.deleteSpace).
    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Removes every Space of a profile.
    func removeAll(for profile: UUID?) {
        items.removeAll { $0.profile == profile }
        persist()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(items.count - 1, i + offset))
        guard i != j else { return }
        items.swapAt(i, j)
        persist()
    }

    func isOpen(_ id: UUID) -> Bool {
        WindowRegistry.shared.browsers.contains { !$0.isPrivate && !$0.isClosed && $0.spaceID == id }
    }

    private func persist() { file.save(items) }

    /// Written at once, for when Tacet quits.
    func saveNow() { file.saveNow(items) }
}
