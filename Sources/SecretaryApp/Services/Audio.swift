import AppKit
import AVFoundation
import SecretaryCore

/// Records a dictated request to a temporary AAC file.
@MainActor
final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("request-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record(forDuration: 120) else {
            throw NSError(domain: "VoiceRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not start recording."])
        }
        self.recorder = recorder
        fileURL = url
    }

    /// Stops and returns the recorded file.
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        return fileURL
    }

    var isRecording: Bool { recorder?.isRecording ?? false }
}

@MainActor
enum AlarmVoiceCatalog {
    static func voices(for language: SpeechLanguage) -> [AVSpeechSynthesisVoice] {
        let prefix = language == .ru ? "ru-" : "en-"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                voice.language.hasPrefix(prefix)
                    && (voice.quality.rawValue > 1
                        || (voice.identifier.hasPrefix("com.apple.voice.")
                            && !voice.identifier.contains("super-compact")))
            }
            .sorted { left, right in
                if left.quality.rawValue != right.quality.rawValue {
                    return left.quality.rawValue > right.quality.rawValue
                }
                return left.name < right.name
            }
    }

    static func preferred(for language: SpeechLanguage) -> AVSpeechSynthesisVoice? {
        voices(for: language).first ?? AVSpeechSynthesisVoice(language: language == .ru ? "ru-RU" : "en-US")
    }

    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        if voice.identifier.contains("gryphon-neural_Yelena") { return "Yelena · natural · Russian" }
        if voice.identifier.contains("siri.natural.Nora") { return "Nora · natural · English" }
        return "\(voice.name) · \(voice.language)"
    }
}

/// Local macOS speech synthesis; no network (DEC-016).
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voiceID: @MainActor (SpeechLanguage) -> String?
    private var finished: CheckedContinuation<Void, Never>?
    private var generation = 0

    init(voiceID: @escaping @MainActor (SpeechLanguage) -> String? = { _ in nil }) {
        self.voiceID = voiceID
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: SpeechLanguage) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceID(language).flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AlarmVoiceCatalog.preferred(for: language)
        // Watchdog: if the delegate callback never arrives, stop waiting after a generous estimate.
        let limit = Double(text.count) * 0.12 + 10
        generation += 1
        let current = generation
        await withCheckedContinuation { cont in
            finished = cont
            synthesizer.speak(utterance)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                guard let self, self.generation == current else { return }
                self.resume()
            }
        }
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        resume()
    }

    private func resume() {
        finished?.resume()
        finished = nil
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }
}

/// Alarm playback: sound once, then speech once, then a persistent panel (REQ-004, DEC-008, DEC-025).
@MainActor
final class AlarmPresenter: AlarmPresenting {
    private let speaker: Speaker
    private let panels: AlarmPanelController
    var onSnooze: ((AlarmContent, Int) -> Void)?
    var onHabitDone: ((AlarmContent) -> Void)?
    var isHabit: ((UUID) -> Bool)?
    private var activeTokens = Set<UUID>()
    private var cancelledTokens = Set<UUID>()
    private var sounds: [UUID: NSSound] = [:]

    init(speaker: Speaker, panels: AlarmPanelController) {
        self.speaker = speaker
        self.panels = panels
    }

    func present(_ alarm: AlarmContent) async {
        let token = UUID()
        activeTokens.insert(token)
        defer {
            activeTokens.remove(token)
            cancelledTokens.remove(token)
            sounds.removeValue(forKey: token)
        }
        panels.show(alarm, snooze: { [weak self] minutes in
            self?.stopPlayback(token)
            self?.onSnooze?(alarm, minutes)
        }, done: isHabit?(alarm.eventID) == true ? { [weak self] in
            self?.stopPlayback(token)
            self?.onHabitDone?(alarm)
        } : nil, onDismiss: { [weak self] in self?.stopPlayback(token) })
        let selected = AlarmSoundLibrary.url(for: alarm.soundID)
            .flatMap { NSSound(contentsOf: $0, byReference: false) }
        if let sound = selected ?? NSSound(named: "Glass") ?? NSSound(named: "Ping") {
            sounds[token] = sound
            _ = sound.play()
            let seconds = min(15, max(0.8, sound.duration))
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if sound.isPlaying { sound.stop() }
        }
        guard !cancelledTokens.contains(token) else { return }
        await speaker.speak(alarm.spokenText, language: alarm.language)
    }

    private func stopPlayback(_ token: UUID) {
        guard activeTokens.contains(token) else { return }
        cancelledTokens.insert(token)
        sounds[token]?.stop()
        speaker.stop()
    }
}
