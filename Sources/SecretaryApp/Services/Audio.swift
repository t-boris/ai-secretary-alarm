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

/// Alarm playback: show controls and play music immediately, then play the chosen AI voice if available.
@MainActor
final class AlarmPresenter: AlarmPresenting {
    private let speech: OpenAIClient
    private let settings: @MainActor () -> AppSettings
    private let panels: AlarmPanelController
    var onSnooze: ((AlarmContent, Int) -> Void)?
    var onHabitDone: ((AlarmContent) -> Void)?
    var isHabit: ((UUID) -> Bool)?
    private var activeTokens = Set<UUID>()
    private var cancelledTokens = Set<UUID>()
    private var sounds: [UUID: NSSound] = [:]
    private var speechRequests: [UUID: Task<Data?, Never>] = [:]
    private var audioCache: [String: Data] = [:]

    init(speech: OpenAIClient, settings: @escaping @MainActor () -> AppSettings, panels: AlarmPanelController) {
        self.speech = speech
        self.settings = settings
        self.panels = panels
    }

    func present(_ alarm: AlarmContent) async {
        let token = UUID()
        activeTokens.insert(token)
        defer {
            activeTokens.remove(token)
            cancelledTokens.remove(token)
            sounds.removeValue(forKey: token)
            speechRequests.removeValue(forKey: token)?.cancel()
        }
        let configured = settings()
        let cacheKey = "\(configured.alarmCloudVoice.rawValue)|\(configured.alarmRussianStyle.rawValue)|\(alarm.language.rawValue)|\(alarm.spokenText)"
        if configured.alarmSpeechEnabled && audioCache[cacheKey] == nil {
            let speech = self.speech
            speechRequests[token] = Task {
                try? await speech.speechAudio(text: alarm.spokenText, language: alarm.language,
                                              voice: configured.alarmCloudVoice,
                                              russianStyle: configured.alarmRussianStyle)
            }
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
        guard configured.alarmSpeechEnabled else { return }
        let audio: Data?
        if let cached = audioCache[cacheKey] {
            audio = cached
        } else if let request = speechRequests[token] {
            audio = await withDeadline(15, fallback: Optional<Data>.none) { await request.value }
        } else {
            audio = nil
        }
        guard !cancelledTokens.contains(token), let audio, let spoken = NSSound(data: audio) else { return }
        if audioCache.count >= 8 { audioCache.removeAll() }
        audioCache[cacheKey] = audio
        sounds[token] = spoken
        _ = spoken.play()
        let seconds = min(90, max(0.8, spoken.duration))
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if spoken.isPlaying { spoken.stop() }
    }

    private func stopPlayback(_ token: UUID) {
        guard activeTokens.contains(token) else { return }
        cancelledTokens.insert(token)
        sounds[token]?.stop()
        speechRequests[token]?.cancel()
    }
}
