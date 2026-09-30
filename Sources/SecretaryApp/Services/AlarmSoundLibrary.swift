import AppKit
import SecretaryCore
import UniformTypeIdentifiers

/// Bundled short melodies and copies of audio chosen by the user.
@MainActor
enum AlarmSoundLibrary {
    struct Option: Identifiable {
        let id: String
        let title: String
    }

    static let builtIn: [Option] = [
        .init(id: "built-in:training", title: "Training · upbeat"),
        .init(id: "built-in:meeting", title: "Meeting · calm"),
        .init(id: "built-in:appointment", title: "Appointment · gentle"),
        .init(id: "built-in:social", title: "Social · bright"),
        .init(id: "built-in:other", title: "Other · soft"),
    ]

    private static var directory: URL {
        JSONFileStore.defaultURL().deletingLastPathComponent().appendingPathComponent("Sounds", isDirectory: true)
    }

    static var options: [Option] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let custom = files.filter { !$0.hasDirectoryPath }.map { file in
            let name = file.lastPathComponent
            let title = file.deletingPathExtension().lastPathComponent
                .components(separatedBy: "--").dropFirst().joined(separator: "--")
            return Option(id: "custom:\(name)", title: "Personal · \(title.isEmpty ? name : title)")
        }.sorted { $0.title < $1.title }
        return builtIn + custom
    }

    static func url(for id: String) -> URL? {
        if let type = id.hasPrefix("built-in:") ? String(id.dropFirst("built-in:".count)) : nil,
           EventType(rawValue: type) != nil {
            let url = Bundle.main.resourceURL?.appendingPathComponent("Sounds/\(type).wav")
            return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        }
        guard id.hasPrefix("custom:") else { return nil }
        let name = String(id.dropFirst("custom:".count))
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns nil if the file picker was cancelled.
    static func importAudio() throws -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use for alarms"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return nil }
        let size = (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 25_000_000 else { throw problem("Choose an audio file smaller than 25 MB.") }
        let ext = source.pathExtension.lowercased()
        guard ["mp3", "m4a", "wav", "aif", "aiff", "caf"].contains(ext) else {
            throw problem("Choose an MP3, M4A, WAV, AIFF, or CAF audio file.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = String(source.deletingPathExtension().lastPathComponent.prefix(60))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "--", with: "-")
        let name = "\(UUID().uuidString)--\(base).\(ext)"
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: target)
        guard NSSound(contentsOf: target, byReference: false) != nil else {
            try? FileManager.default.removeItem(at: target)
            throw problem("This audio file could not be played by macOS.")
        }
        return "custom:\(name)"
    }

    private static func problem(_ text: String) -> NSError {
        NSError(domain: "AlarmSoundLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
