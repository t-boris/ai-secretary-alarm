import SecretaryCore
import SwiftUI

/// Conversation, clarifying questions and the confirmation summary (REQ-002, DEC-015).
struct AssistantView: View {
    static let windowID = "assistant"

    @Environment(AppCoordinator.self) private var app
    @State private var reply = ""

    private var assistant: AssistantController { app.assistant }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            conversation
            if case let .summary(draft, lines) = assistant.phase {
                SummaryView(draft: draft, lines: lines, banner: assistant.banner)
            }
            if case let .existing(draft, matches) = assistant.phase {
                ExistingEventsView(draft: draft, matches: matches, banner: assistant.banner)
            }
            status
            inputBar
        }
        .padding(16)
        .frame(minWidth: 720, idealWidth: 840, minHeight: 560, idealHeight: 660)
    }

    private var conversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if assistant.log.isEmpty {
                    Text("Say or type something like “meeting with Manoj at 10:30 today” or “training every Mon/Wed/Fri at 6 pm”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(assistant.log.enumerated()), id: \.offset) { _, turn in
                    HStack {
                        if turn.role == .user { Spacer(minLength: 40) }
                        Text(turn.text)
                            .padding(8)
                            .background(turn.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                        if turn.role == .assistant { Spacer(minLength: 40) }
                    }
                }
            }
        }
        .frame(minHeight: 160, maxHeight: .infinity)
    }

    @ViewBuilder private var status: some View {
        switch assistant.phase {
        case .recording:
            Label("Listening… press the mic again to send", systemImage: "waveform").foregroundStyle(.red)
        case let .working(text):
            HStack { ProgressView().controlSize(.small); Text(text) }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    private var inputBar: some View {
        HStack {
            Button {
                Task { await assistant.toggleRecording() }
            } label: {
                Image(systemName: assistant.isRecording ? "stop.circle.fill" : "mic.circle.fill").font(.title)
            }
            .buttonStyle(.borderless)
            .disabled(assistant.isBusy)
            .help("Dictate (answer, 'yes' to confirm, a correction, or 'cancel')")

            TextField("Reply or type a request", text: $reply)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .disabled(assistant.isBusy)
            Button("Send", action: send).disabled(reply.isEmpty || assistant.isBusy)
            Button("Clear") { assistant.reset() }
        }
    }

    private func send() {
        let text = reply
        reply = ""
        Task { await assistant.submit(text) }
    }
}

/// Lets the user attach reminders to an event already in Google Calendar.
private struct ExistingEventsView: View {
    @Environment(AppCoordinator.self) private var app
    let draft: EventDraft
    let matches: [GoogleEvent]
    let banner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let banner { Label(banner, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            Text("Calendar events already exist near this time. Choose one to add reminders without creating another event.")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(matches.indices, id: \.self) { index in
                        let event = matches[index]
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.summary ?? "Untitled event").fontWeight(.medium)
                                if let start = GoogleTime.parse(event.start, fallbackZone: draft.timeZone) {
                                    Text(start.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Use for reminders") { Task { await app.assistant.useExisting(event) } }
                        }
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 250)
            HStack {
                Button("Cancel", role: .cancel) { Task { await app.assistant.cancel() } }
                Spacer()
                Button("Create a separate event") { Task { await app.assistant.createSeparate() } }
            }
        }
    }
}

/// Summary with editable fields; confirm by click or by saying "yes" (DEC-015).
private struct SummaryView: View {
    @Environment(AppCoordinator.self) private var app
    let draft: EventDraft
    let lines: [String]
    let banner: String?
    @State private var edited: EventDraft?

    private var current: EventDraft { edited ?? draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let banner {
                Label(banner, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines, id: \.self) { Text($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Edit") { editor }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { Task { await app.assistant.cancel() } }
                if edited != nil && edited != draft {
                    Button("Apply changes") {
                        let d = current
                        edited = nil
                        Task { await app.assistant.edit(d) }
                    }
                } else {
                    Button("Create") { Task { await app.assistant.confirm() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onChange(of: draft) { edited = nil }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<EventDraft, T>) -> Binding<T> {
        Binding(get: { current[keyPath: keyPath] },
                set: { var d = current; d[keyPath: keyPath] = $0; edited = d })
    }

    private var editor: some View {
        Form {
            TextField("Title", text: binding(\.title))
            DatePicker("Start", selection: Binding(
                get: { current.start },
                set: { newStart in
                    var d = current
                    let duration = d.end.timeIntervalSince(d.start)
                    d.start = newStart
                    d.end = newStart.addingTimeInterval(duration)
                    edited = d
                }))
            Picker("Location", selection: binding(\.locationType)) {
                Text("Home").tag(LocationType.home)
                Text("Off-site").tag(LocationType.offSite)
                Text("No location / online").tag(LocationType.noLocation)
            }
            AlarmSoundPicker(label: "Alarm music", selection: Binding(
                get: { current.alarmSoundID ?? "" },
                set: { sound in
                    var d = current
                    d.alarmSoundID = sound.isEmpty ? nil : sound
                    edited = d
                }), allowsTypeDefault: true)
            if current.locationType == .offSite {
                Picker("Leave from", selection: binding(\.origin)) {
                    Text("Current location (home if unknown)").tag(OriginChoice.automatic)
                    ForEach(app.store.state.places) { place in
                        Text(place.isHome ? "Home" : place.name).tag(OriginChoice.place(place.id))
                    }
                }
                Stepper("Preparation: \(current.prepMinutes) min", value: binding(\.prepMinutes), in: 0...180, step: 5)
                if let name = current.newPlaceName {
                    Toggle("Save as “\(name)”", isOn: binding(\.savePlace))
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 280)
    }
}
