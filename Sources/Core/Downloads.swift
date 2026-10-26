import AppKit
import WebKit

final class DownloadItem: NSObject, ObservableObject, Identifiable {
    enum State: Equatable { case active, finished, failed(String), cancelled }

    let id = UUID()
    let download: WKDownload
    let source: URL?
    @Published var filename = L("Download")
    @Published var destination: URL?
    @Published var fraction = 0.0
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var state = State.active
    let started = Date()
    private var observation: NSKeyValueObservation?
    private var lastUpdate = Date.distantPast

    init(_ download: WKDownload) {
        self.download = download
        source = download.originalRequest?.url
        super.init()
        observation = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let fraction = p.fractionCompleted
            let done = p.completedUnitCount
            let total = p.totalUnitCount
            DispatchQueue.main.async {
                guard let self else { return }
                // Progress arrives for every chunk; ten redraws a second are plenty.
                let now = Date()
                guard fraction >= 1 || now.timeIntervalSince(self.lastUpdate) >= 0.1 else { return }
                self.lastUpdate = now
                self.fraction = fraction
                self.received = done
                self.total = total
            }
        }
    }

    var statusText: String {
        let f = ByteCountFormatter()
        switch state {
        case .active:
            return total > 0 ? String(format: L("%@ of %@"), f.string(fromByteCount: received), f.string(fromByteCount: total)) : f.string(fromByteCount: received)
        case .finished: return f.string(fromByteCount: max(total, received))
        case .failed(let reason): return reason
        case .cancelled: return L("Cancelled")
        }
    }

    var icon: NSImage {
        if let destination, FileManager.default.fileExists(atPath: destination.path) {
            return NSWorkspace.shared.icon(forFile: destination.path)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}

final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    @Published private(set) var items: [DownloadItem] = []
    @Published var unseen = false

    var active: [DownloadItem] { items.filter { $0.state == .active } }
    var overallFraction: Double {
        let a = active
        return a.isEmpty ? 1 : a.map(\.fraction).reduce(0, +) / Double(a.count)
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        items.insert(DownloadItem(download), at: 0)
        unseen = true
    }

    private func item(for download: WKDownload) -> DownloadItem? { items.first { $0.download === download } }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let name = suggestedFilename.isEmpty ? L("Download") : suggestedFilename
        item(for: download)?.filename = name
        if Settings.shared.confirmDangerousDownloads, Self.isDangerous(name) {
            let host = download.originalRequest?.url?.host ?? ""
            Dialogs.confirm(NSApp.keyWindow, title: String(format: L("“%@” can make changes to your Mac"), name),
                            message: String(format: L("Apps, installers and scripts can harm your Mac. Download it only if you trust %@."), host.isEmpty ? L("this site") : host),
                            ok: L("Download Anyway"), cancel: L("Cancel")) { ok in
                if ok {
                    self.chooseDestination(download, name: name, completionHandler: completionHandler)
                } else {
                    self.item(for: download)?.state = .cancelled
                    completionHandler(nil)
                }
            }
            return
        }
        chooseDestination(download, name: name, completionHandler: completionHandler)
    }

    static let dangerousExtensions: Set<String> = [
        "dmg", "pkg", "mpkg", "app", "command", "sh", "zsh", "bash", "tool", "terminal", "scpt", "applescript",
        "workflow", "action", "prefpane", "kext", "jar", "bin", "run", "exe", "msi", "bat", "ps1", "py", "pl", "rb",
    ]

    static func isDangerous(_ name: String) -> Bool {
        dangerousExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private func chooseDestination(_ download: WKDownload, name: String, completionHandler: @escaping (URL?) -> Void) {
        if Settings.shared.askDownloadLocation {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.begin { [weak self] result in
                guard result == .OK, let url = panel.url else {
                    self?.item(for: download)?.state = .cancelled
                    completionHandler(nil)
                    return
                }
                try? FileManager.default.removeItem(at: url)
                self?.item(for: download)?.destination = url
                self?.item(for: download)?.filename = url.lastPathComponent
                completionHandler(url)
            }
            return
        }
        let url = Self.uniqueURL(name)
        item(for: download)?.destination = url
        item(for: download)?.filename = url.lastPathComponent
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        item.fraction = 1
        if let path = item.destination?.path {
            // Bounces the Downloads stack in the Dock, like Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let e = error as NSError
        item(for: download)?.state = e.code == NSURLErrorCancelled ? .cancelled : .failed(e.localizedDescription)
    }

    func cancel(_ item: DownloadItem) {
        item.download.cancel { _ in }
        item.state = .cancelled
    }

    func reveal(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ item: DownloadItem) {
        guard let url = item.destination, item.state == .finished else { return }
        NSWorkspace.shared.open(url)
    }

    func clearFinished() {
        items.removeAll { $0.state != .active }
    }

    static func uniqueURL(_ name: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var url = folder.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
