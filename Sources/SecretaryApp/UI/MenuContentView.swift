import AppKit
import SecretaryCore
import SwiftUI

/// Menu bar popover: dictation entry point, typed input and the list of upcoming assistant events (DEC-015).
struct MenuContentView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var typed = ""
    @State private var pendingDelete: UUID?
    @State private var deleteError: String?
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 8) {
                Button {
                    Task {
                        await app.assistant.toggleRecording(autoCreate: true)
                        if app.assistant.needsWindow { openAssistant() }
                    }
                } label: {
                    Image(systemName: app.assistant.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .tint(app.assistant.isRecording ? .red : .accentColor)
                .disabled(app.assistant.isBusy)
                .help(app.assistant.isRecording ? "Stop recording and send" : "Speak a request")

                TextField("Type a request…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .disabled(app.assistant.isBusy)
                    .onSubmit {
                        let text = typed
                        typed = ""
                        Task {
                            await app.assistant.submit(text, autoCreate: true)
                            if app.assistant.needsWindow { openAssistant() }
                        }
                    }
            }

            requestStatus

            if let loadError = app.store.loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            }
            Divider()
            upcomingList
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 460)
    }

    @ViewBuilder private var requestStatus: some View {
        switch app.assistant.phase {
        case let .working(text):
            HStack { ProgressView().controlSize(.small); Text(text) }
                .font(.caption)
        case .recording:
            Text("Listening… press the microphone again to send.")
                .font(.caption).foregroundStyle(.secondary)
        case let .question(text):
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        case let .finished(text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .summary:
            if let banner = app.assistant.banner {
                Text(banner).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Review event") { openAssistant() }
        case .existing:
            Button("Choose an existing event") { openAssistant() }
        case .idle:
            EmptyView()
        }
    }

    private var header: some View {
        HStack {
            Text("AI Secretary").font(.headline)
            Spacer()
            if !app.googleSignedIn {
                Label("Calendar not connected", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var upcomingList: some View {
        let items = app.upcoming()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Upcoming").font(.subheadline).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("No upcoming reminders or calendar events.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items.prefix(3), id: \.record.id) { item in
                        row(item.record, item.occurrence)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if items.count > 3 {
                    Button(showMore ? "Show fewer" : "Show \(items.count - 3) more") { showMore.toggle() }
                        .buttonStyle(.link)
                    if showMore {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(items.dropFirst(3).prefix(20), id: \.record.id) { item in
                                    row(item.record, item.occurrence)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: min(280, CGFloat(min(items.count - 3, 20)) * 76))
                    }
                }
            }
            if let deleteError {
                Text(deleteError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func row(_ record: EventRecord, _ occurrence: Occurrence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: record.isStandaloneReminder ? "bell" : icon(occurrence.locationType))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(occurrence.title).fontWeight(.medium).lineLimit(2)
                    Text(record.isHabit ? "Daily check-in" : record.isStandaloneReminder ? "Reminder" : "Calendar event")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(occurrence.start.formatted(date: .abbreviated, time: .shortened)
                         + (record.recurrence != nil ? " · repeats" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if record.isHabit {
                    Button { app.markHabitDone(record, occurrence) } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Mark done today")
                }
                if pendingDelete != record.id {
                    Menu {
                        if !record.isStandaloneReminder, let link = record.htmlLink.flatMap(URL.init(string:)) {
                            Button("Open in Google Calendar") { NSWorkspace.shared.open(link) }
                        }
                        Menu("Alarm music") {
                            Button("Use \(record.eventType.rawValue) default") { setSound(nil, for: record) }
                            ForEach(AlarmSoundLibrary.options) { option in
                                Button(option.title) { setSound(option.id, for: record) }
                            }
                            Divider()
                            Button("Import audio…") {
                                do {
                                    if let id = try AlarmSoundLibrary.importAudio() { setSound(id, for: record) }
                                } catch { deleteError = error.localizedDescription }
                            }
                        }
                        Divider()
                        Button(record.isHabit ? "Remove daily check-in" : record.isStandaloneReminder ? "Remove reminder"
                               : record.managesGoogleEvent == false ? "Remove reminders" : "Delete event",
                               role: .destructive) { pendingDelete = record.id }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Event actions")
                }
            }
            if pendingDelete == record.id {
                Text(record.isHabit ? "Remove this daily check-in?" : record.isStandaloneReminder ? "Remove this local reminder?"
                     : record.managesGoogleEvent == false ? "Remove these reminders? The calendar event will stay."
                     : "Delete this event from Google Calendar?")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 30)
                HStack {
                    Spacer()
                    Button("Keep") { pendingDelete = nil }
                    Button(record.managesGoogleEvent == true && !record.isStandaloneReminder ? "Delete" : "Remove",
                           role: .destructive) {
                        Task {
                            deleteError = await app.delete(record)
                            pendingDelete = nil
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func setSound(_ id: String?, for record: EventRecord) {
        app.store.mutate { state in
            guard let index = state.events.firstIndex(where: { $0.id == record.id }) else { return }
            state.events[index].alarmSoundID = id
        }
    }

    private var footer: some View {
        HStack {
            Button("Assistant") { openAssistant() }
            Button("Settings…") {
                openSettings()
                DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
    }

    private func icon(_ type: LocationType) -> String {
        switch type {
        case .home: return "house"
        case .offSite: return "car"
        case .noLocation: return "video"
        }
    }

    private func openAssistant() {
        openWindow(id: AssistantView.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
