import AppKit

/// The app icons you can pick in Settings › Appearance and during setup.
///
/// Seal, corona is the default and is the icon inside the app bundle. The others are pictures in
/// Resources/AppIcons, drawn by tools/make-icons.py. A chosen icon shows in the Dock while Tacet runs and is also
/// set on Tacet.app itself, so Finder and the Dock show it when Tacet is closed. An update replaces the app and
/// with it that icon, so it is put back at the next launch.
struct AppIcon: Identifiable, Hashable {
    let id: String
    /// English name, translated with L().
    let name: String

    static let defaultID = "seal-corona"

    /// In the order they're offered. Keep in step with FINALS in tools/make-icons.py.
    static let all: [AppIcon] = [
        AppIcon(id: "seal-corona", name: "Seal, corona"),
        AppIcon(id: "seal-night-gold", name: "Gold seal"),
        AppIcon(id: "seal-night-half", name: "Half seal"),
        AppIcon(id: "seal-night-t", name: "Seal, t."),
        AppIcon(id: "half-seal-t", name: "Half seal, t."),
        AppIcon(id: "t-gold-coin", name: "t. coin"),
        AppIcon(id: "t-gold-ocean", name: "t., ocean"),
        AppIcon(id: "t-gold-halfground", name: "t., half lit"),
        AppIcon(id: "half-moon-stop", name: "Half moon"),
        AppIcon(id: "half-moon-t", name: "Half moon, t"),
        AppIcon(id: "half-moon-soft", name: "Half moon, soft"),
        AppIcon(id: "half-moon-corona", name: "Half moon, corona"),
        AppIcon(id: "corona-gold", name: "Corona, gold"),
        AppIcon(id: "corona-t-bold", name: "Corona t"),
        AppIcon(id: "corona-t-gold", name: "Corona t, gold"),
        AppIcon(id: "last-light-rim", name: "Last light"),
        AppIcon(id: "eclipse", name: "Eclipse (until 1.6.4)"),
    ]

    var isDefault: Bool { id == Self.defaultID }

    /// The picture for this icon, or the bundle's own icon for the default.
    var image: NSImage? {
        if isDefault { return Bundle.main.image(forResource: "Tacet") }
        guard let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "AppIcons") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func find(_ id: String) -> AppIcon { all.first { $0.id == id } ?? all[0] }

    // MARK: Applying

    /// Marks which icon was last set on the bundle, with the build it was set on, so an unchanged choice
    /// doesn't rewrite the app at every launch while an update (a new build) gets it back.
    private static let appliedKey = "lumen.appIconApplied"
    private static var buildStamp: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "" }

    /// Shows the chosen icon in the Dock and, when it changed or Tacet was updated, sets it on the app in Finder.
    /// Copies of Tacet made for sites installed as apps keep their own icon.
    static func applyChosen(force: Bool = false) {
        guard !WebApp.isActive else { return }
        let icon = find(Settings.shared.appIcon)
        NSApp.applicationIconImage = icon.isDefault ? nil : icon.image
        let stamp = icon.id + "@" + buildStamp
        guard force || UserDefaults.standard.string(forKey: appliedKey) != stamp else { return }
        let bundle = Bundle.main.bundlePath
        // The default needs nothing done to an app that has no custom icon.
        if icon.isDefault, !FileManager.default.fileExists(atPath: bundle + "/Icon\r") {
            UserDefaults.standard.set(stamp, forKey: appliedKey)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            // nil removes a custom icon, so the bundle's own (the default) shows again.
            let image = icon.isDefault ? nil : icon.image
            let ok = NSWorkspace.shared.setIcon(image, forFile: bundle, options: [])
            DispatchQueue.main.async {
                if ok { UserDefaults.standard.set(stamp, forKey: appliedKey) }
            }
        }
    }

    /// Takes a custom icon off a copy of Tacet, before it's signed: codesign refuses the extra icon file the
    /// custom icon puts in the bundle, and a site installed as an app should show the site's icon anyway.
    static func stripCustomIcon(at app: URL) {
        let marker = app.appendingPathComponent("Icon\r")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        NSWorkspace.shared.setIcon(nil, forFile: app.path, options: [])
        try? FileManager.default.removeItem(at: marker)
    }
}
