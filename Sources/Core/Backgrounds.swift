import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Custom start page backgrounds, copied into Tacet's own folder so they keep working
/// if the original file moves.
enum BackgroundMedia {
    static let maxVideoSeconds = 60.0
    static let maxVideoBytes = 300 * 1024 * 1024
    static let videoTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "m4v") ?? .movie]
    static let imageTypes: [UTType] = [.jpeg, .png, .heic, .webP, .tiff, .gif]

    private static var folder: URL { Paths.folder("Backgrounds") }

    enum Failure: LocalizedError {
        case tooLong, tooBig, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLong: String(format: L("Videos can be up to %lld seconds long."), Int(BackgroundMedia.maxVideoSeconds))
            case .tooBig: L("Videos can be up to 300 MB.")
            case .unreadable: L("Tacet couldn't play this file.")
            }
        }
    }

    static func importImage(_ source: URL) -> Result<String, Failure> {
        guard NSImage(contentsOf: source) != nil else { return .failure(.unreadable) }
        return copy(source, name: "image")
    }

    /// Checks size, length and that the file is playable, then copies it in.
    static func importVideo(_ source: URL, done: @escaping (Result<String, Failure>) -> Void) {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxVideoBytes else { done(.failure(.tooBig)); return }
        let asset = AVURLAsset(url: source)
        Task {
            let duration = try? await asset.load(.duration)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let result: Result<String, Failure>
            if !playable || tracks.isEmpty {
                result = .failure(.unreadable)
            } else if let duration, duration.seconds > maxVideoSeconds + 0.5 {
                result = .failure(.tooLong)
            } else {
                result = copy(source, name: "video")
            }
            await MainActor.run { done(result) }
        }
    }

    private static func copy(_ source: URL, name: String) -> Result<String, Failure> {
        let fm = FileManager.default
        // Remove the previous file of this kind so old backgrounds don't pile up.
        for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent.hasPrefix(name + "-") {
            try? fm.removeItem(at: old)
        }
        let target = folder.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())")
        do {
            try fm.copyItem(at: source, to: target)
            return .success(target.path)
        } catch {
            return .failure(.unreadable)
        }
    }
}
