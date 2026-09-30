import Foundation
import Observation
import SecretaryCore

/// Drives one voice/text request from dictation to a created event (REQ-001, REQ-002).
@MainActor
@Observable
final class AssistantController {
    enum Phase: Equatable {
        case idle
        case recording
        case working(String)
        case question(String)
        case summary(EventDraft, [String])
        case existing(EventDraft, [GoogleEvent])
        case finished(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var log: [ChatTurn] = []
    /// Error shown above the summary when creation failed; the draft is kept for a retry.
    private(set) var banner: String?

    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private let recorder = VoiceRecorder()
    @ObservationIgnored private var session: DialogueSession?
    @ObservationIgnored private var lastSummaryLines: [String] = []
    @ObservationIgnored private var autoCreateOnSummary = false

    init(app: AppCoordinator) { self.app = app }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { if case .working = phase { return true } else { return false } }
    var needsWindow: Bool {
        switch phase {
        case .question, .existing: return true
        default: return false
        }
    }

    // MARK: - Input

    func toggleRecording(autoCreate: Bool = false) async {
        if isRecording {
            await finishRecording(autoCreate: autoCreate)
        } else {
            await startRecording()
        }
    }

    private var previousPhase: Phase = .idle

    private func startRecording() async {
        guard await VoiceRecorder.requestPermission() else {
            phase = .failed("Microphone access is denied. Allow it in System Settings → Privacy & Security → Microphone.")
            return
        }
        do {
            try recorder.start()
            previousPhase = phase
            phase = .recording
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func finishRecording(autoCreate: Bool) async {
        guard let file = recorder.stop() else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        phase = .working("Transcribing…")
        do {
            let text = try await app.openAI.transcribe(audioFile: file)
            phase = previousPhase
            await submit(text, autoCreate: autoCreate)
        } catch let error as AIError {
            fail(error.message(language))
        } catch {
            fail(AIError.service(error.localizedDescription).message(language))
        }
    }

    /// Typed or transcribed input: a new request, an answer, a confirmation or a correction.
    func submit(_ text: String, autoCreate: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if session == nil || isTerminal, let quick = QuickReminderParser.parse(trimmed, now: Date()) {
            session = nil
            log = [ChatTurn(.user, trimmed)]
            banner = nil
            let record = app.createQuickReminder(quick)
            let when = formattedDue(record.start, language: quick.language)
            let done = quick.language == .ru ? "Хорошо, напомню «\(record.title)» \(when)."
                                            : "Okay, I'll remind you about \"\(record.title)\" at \(when)."
            await finish(done, language: quick.language)
            return
        }
        if session == nil || isTerminal {
            session = DialogueSession(parser: app.openAI, geocoder: app.geocoder, travel: app.travel, store: app.store)
            log = []
            banner = nil
        }
        log.append(ChatTurn(.user, trimmed))
        autoCreateOnSummary = autoCreate
        phase = .working("Thinking…")
        guard let session else { return }
        await show(await session.handle(trimmed))
    }

    func confirm() async {
        guard case let .summary(draft, _) = phase else { return }
        await show(.confirmed(draft))
    }

    func useExisting(_ event: GoogleEvent) async {
        guard case let .existing(draft, matches) = phase else { return }
        phase = .working("Linking reminders…")
        do {
            let result = try await app.useExisting(event, for: draft)
            let done: String
            if result.added {
                done = draft.language == .ru ? "Напоминания привязаны к существующему событию «\(result.record.title)». Новое событие не создано."
                                              : "Reminders are linked to the existing event \"\(result.record.title)\". No new event was created."
            } else {
                done = draft.language == .ru ? "Напоминания для «\(result.record.title)» уже настроены. Новое событие не создано."
                                              : "Reminders for \"\(result.record.title)\" are already set up. No new event was created."
            }
            await finish(done, language: draft.language)
        } catch {
            banner = error.localizedDescription
            phase = .existing(draft, matches)
        }
    }

    func createSeparate() async {
        guard case let .existing(draft, matches) = phase else { return }
        phase = .working("Creating a separate event…")
        do {
            let record = try await app.create(draft, createSeparate: true)
            await finish(createdMessage(record, draft: draft), language: draft.language)
            await app.engine.tick()
        } catch {
            banner = error.localizedDescription
            phase = .existing(draft, matches)
        }
    }

    func cancel() async {
        await show(.cancelled)
    }

    /// Field edits from the confirmation form (DEC-015, DEC-014 origin override, DEC-023 save toggle).
    func edit(_ draft: EventDraft) async {
        guard let session else { return }
        autoCreateOnSummary = false
        phase = .working("Updating…")
        await show(await session.edit(draft))
    }

    func reset() {
        if isRecording { _ = recorder.stop() }
        session = nil
        log = []
        banner = nil
        autoCreateOnSummary = false
        phase = .idle
    }

    // MARK: - Output

    private var isTerminal: Bool {
        switch phase {
        case .finished, .failed, .idle: return true
        default: return false
        }
    }

    private var language: SpeechLanguage {
        log.contains { $0.text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil } ? .ru : .en
    }

    private func show(_ step: DialogueStep) async {
        switch step {
        case let .ask(question):
            log.append(ChatTurn(.assistant, question))
            phase = .question(question)
        case let .summary(draft, lines):
            banner = nil
            lastSummaryLines = lines
            phase = .summary(draft, lines)
            // Show the summary before anything is written (DEC-015).
            if autoCreateOnSummary { await show(.confirmed(draft)) }
        case let .confirmed(draft):
            phase = .working("Creating the event…")
            do {
                let record = try await app.create(draft)
                await finish(createdMessage(record, draft: draft), language: draft.language)
                await app.engine.tick()
            } catch let found as ExistingEventsFound {
                banner = nil
                phase = .existing(draft, found.events)
            } catch {
                // Keep the draft so the user can retry after fixing the problem.
                banner = error.localizedDescription
                phase = .summary(draft, lastSummaryLines)
                autoCreateOnSummary = false
            }
        case .cancelled:
            let text = language == .ru ? "Отменено, событие не создано." : "Cancelled. No event was created."
            log.append(ChatTurn(.assistant, text))
            phase = .finished(text)
            session = nil
            autoCreateOnSummary = false
        case let .failed(message):
            fail(message)
        }
    }

    private func createdMessage(_ record: EventRecord, draft: EventDraft) -> String {
        if record.isStandaloneReminder {
            let when = formattedDue(record.start, language: draft.language)
            if record.isHabit {
                let time = record.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                    .locale(Locale(identifier: draft.language == .ru ? "ru_RU" : "en_US")))
                return draft.language == .ru ? "Готово, буду проверять «\(record.title)» каждый день в \(time)."
                                             : "Okay, I'll check in about \"\(record.title)\" every day at \(time)."
            }
            return draft.language == .ru ? "Хорошо, напомню «\(record.title)» \(when)."
                                         : "Okay, I'll remind you about \"\(record.title)\" at \(when)."
        }
        var done = draft.language == .ru ? "Готово: «\(record.title)» добавлено в календарь."
                                         : "Done: \"\(record.title)\" was added to your calendar."
        if getReadyLapsed(record) {
            done += draft.language == .ru ? " Время «пора собираться» уже прошло — будет только «пора выходить»."
                                          : " The 'get ready' time has passed; only 'leave now' is scheduled."
        }
        return done
    }

    private func formattedDue(_ date: Date, language: SpeechLanguage) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(Locale(identifier: language == .ru ? "ru_RU" : "en_US")))
    }

    private func finish(_ message: String, language: SpeechLanguage) async {
        log.append(ChatTurn(.assistant, message))
        phase = .finished(message)
        session = nil
        autoCreateOnSummary = false
    }

    /// True when the first 'get ready' fell before creation (DEC-022), e.g. because confirmation came late.
    private func getReadyLapsed(_ record: EventRecord) -> Bool {
        let settings = app.store.state.settings
        guard let first = record.occurrences(from: record.createdAt, through: record.createdAt.addingTimeInterval(400 * 86_400)).first
        else { return false }
        return ReminderPlanner.reminders(for: first, record: record, settings: settings)
            .contains { ReminderPlanner.isSkippedAtCreation($0, createdAt: record.createdAt) }
    }

    private func fail(_ message: String) {
        log.append(ChatTurn(.assistant, message))
        phase = .failed(message)
        session = nil
    }
}
