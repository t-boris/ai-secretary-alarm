import Foundation

/// The model-list API exposes IDs and availability, but no endpoint capability field.
/// Keep the pickers limited to model families this app can call.
public enum OpenAIModelPurpose: Sendable {
    case transcription
    case chat

    public func choices(from availableIDs: [String]) -> [String] {
        Array(Set(availableIDs.filter(accepts))).sorted()
    }

    private func accepts(_ id: String) -> Bool {
        let name = id.lowercased()
        switch self {
        case .transcription:
            return name == "whisper-1" ||
                (name.contains("transcribe") &&
                 !name.contains("diarize") &&
                 !name.contains("live") &&
                 !name.contains("realtime"))
        case .chat:
            let base = name.hasPrefix("ft:") ? String(name.dropFirst(3)) : name
            let isChatFamily = base.hasPrefix("gpt-") || base.hasPrefix("chatgpt-") ||
                (base.first == "o" && base.dropFirst().first?.isNumber == true)
            guard isChatFamily else { return false }
            let otherUses = ["audio", "realtime", "transcribe", "tts", "image", "embedding",
                             "moderation", "search", "deep-research", "instruct", "live",
                             "codex", "video", "sora"]
            return !otherUses.contains(where: base.contains)
        }
    }
}
