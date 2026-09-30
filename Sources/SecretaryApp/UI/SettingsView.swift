import AVFoundation
import SecretaryCore
import SwiftUI

/// Settings: reminders (REQ-005), places (DEC-011, DEC-023), accounts and secrets (DEC-012, DEC-024).
struct SettingsView: View {
    var body: some View {
        TabView {
            RemindersTab().tabItem { Label("Reminders", systemImage: "alarm") }
            PlacesTab().tabItem { Label("Places", systemImage: "mappin.and.ellipse") }
            AccountsTab().tabItem { Label("Accounts", systemImage: "key") }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 560, idealHeight: 660)
    }
}

private struct RemindersTab: View {
    @Environment(AppCoordinator.self) private var app

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { app.store.state.settings[keyPath: keyPath] },
                set: { value in app.store.mutate { $0.settings[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { app.store.state.settings.launchAtLogin },
                    set: { on in
                        app.store.mutate { $0.settings.launchAtLogin = on }
                        app.applyLaunchAtLogin(on)
                    }))
                if let error = app.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Lead times") {
                Stepper("Home / online events: \(app.store.state.settings.homeLeadMinutes) min before",
                        value: binding(\.homeLeadMinutes), in: 0...120)
                Stepper("Fallback travel buffer: \(app.store.state.settings.fallbackBufferMinutes) min",
                        value: binding(\.fallbackBufferMinutes), in: 5...240, step: 5)
                Picker("Default transport", selection: binding(\.transportMode)) {
                    Text("Driving").tag(TransportMode.driving)
                    Text("Public transit").tag(TransportMode.transit)
                    Text("Walking").tag(TransportMode.walking)
                }
            }
            Section("Preparation time by event type") {
                ForEach(EventType.allCases, id: \.self) { type in
                    Stepper("\(type.rawValue.capitalized): \(app.store.state.settings.prepMinutes(for: type)) min",
                            value: Binding(get: { app.store.state.settings.prepMinutes(for: type) },
                                           set: { v in app.store.mutate { $0.settings.prepMinutesByType[type] = v } }),
                            in: 0...180, step: 5)
                }
            }
            Section("Alarm voice") {
                voicePicker("English", language: .en, keyPath: \.alarmVoiceEnglishID)
                voicePicker("Russian", language: .ru, keyPath: \.alarmVoiceRussianID)
                Text("Only scheduled alarms play sound and speak. The clearest installed voice is selected automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Alarm music by event type") {
                ForEach(EventType.allCases, id: \.self) { type in
                    AlarmSoundPicker(label: type.rawValue.capitalized, selection: Binding(
                        get: { app.store.state.settings.alarmSound(for: type) },
                        set: { sound in app.store.mutate { $0.settings.alarmSoundsByType[type] = sound } }))
                }
                Text("Each event type has its own melody. You can import personal audio here or for an individual event.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func voicePicker(_ label: String, language: SpeechLanguage,
                             keyPath: WritableKeyPath<AppSettings, String?>) -> some View {
        let voices = AlarmVoiceCatalog.voices(for: language)
        return Picker(label, selection: Binding(
            get: { app.store.state.settings[keyPath: keyPath] ?? "" },
            set: { id in app.store.mutate { $0.settings[keyPath: keyPath] = id.isEmpty ? nil : id } })) {
            Text("Automatic (best available)").tag("")
            ForEach(voices, id: \.identifier) { voice in
                Text(AlarmVoiceCatalog.label(voice)).tag(voice.identifier)
            }
        }
        .pickerStyle(.menu)
    }
}

private struct PlacesTab: View {
    @Environment(AppCoordinator.self) private var app
    @State private var homeAddress = ""
    @State private var message: String?
    @State private var findingLocation = false
    @State private var addressEdits: [UUID: String] = [:]

    var body: some View {
        Form {
            Section("Home") {
                if let home = app.store.state.home {
                    Text(home.address).textSelection(.enabled)
                }
                HStack {
                    TextField("Home address", text: $homeAddress)
                    Button("Find and save") {
                        Task {
                            message = await app.setHome(address: homeAddress)
                            if message == nil { homeAddress = "" }
                        }
                    }
                    .disabled(homeAddress.isEmpty)
                }
                Button {
                    findingLocation = true
                    Task {
                        let result = await app.currentAddress()
                        if let address = result.address {
                            homeAddress = address
                            message = "Location found. Review the address, then choose Find and save."
                        } else {
                            message = result.error
                        }
                        findingLocation = false
                    }
                } label: {
                    Label(findingLocation ? "Finding location…" : "Find my location", systemImage: "location")
                }
                .disabled(findingLocation)
                Text("Uses this Mac's location to suggest an address. Review it before saving as Home.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saved places") {
                let places = app.store.state.places.filter { !$0.isHome }
                if places.isEmpty {
                    Text("Places are offered for saving when you confirm an event at a new named place.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(places) { place in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("Name", text: Binding(
                                get: { place.name },
                                set: { name in app.store.mutate { s in
                                    if let i = s.places.firstIndex(where: { $0.id == place.id }) { s.places[i].name = name }
                                } }))
                            Button(role: .destructive) {
                                app.store.mutate { $0.places.removeAll { $0.id == place.id } }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        HStack {
                            TextField("Address", text: Binding(get: { addressEdits[place.id] ?? place.address },
                                                               set: { addressEdits[place.id] = $0 }))
                            if let edit = addressEdits[place.id], edit != place.address {
                                Button("Find") {
                                    Task {
                                        message = await app.relocate(placeID: place.id, address: edit)
                                        if message == nil { addressEdits[place.id] = nil }
                                    }
                                }
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            if let message {
                Text(message).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountsTab: View {
    private let openAIKeysURL = URL(string: "https://platform.openai.com/api-keys")!
    private let transcriptionModelsURL = URL(string: "https://developers.openai.com/api/docs/guides/speech-to-text")!
    private let chatModelsURL = URL(string: "https://developers.openai.com/api/docs/models")!
    private let googleClientsURL = URL(string: "https://console.cloud.google.com/auth/clients")!
    private let googleCalendarAPIURL = URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")!
    private let googleOAuthGuideURL = URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app")!

    @Environment(AppCoordinator.self) private var app
    @State private var apiKey = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var message: String?
    @State private var signingIn = false
    @State private var checkingCalendar = false
    @State private var calendarCheckMessage: String?

    private func modelBinding(_ keyPath: WritableKeyPath<AppSettings, String>) -> Binding<String> {
        Binding(get: { app.store.state.settings[keyPath: keyPath] },
                set: { v in app.store.mutate { $0.settings[keyPath: keyPath] = v } })
    }

    var body: some View {
        Form {
            Section("OpenAI (speech recognition and parsing)") {
                Link("Create an OpenAI API key in browser", destination: openAIKeysURL)
                Text("Create a key in your OpenAI project, then paste it below and save it to the Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("API key", text: $apiKey)
                OpenAIModelPicker(label: "Transcription model", purpose: .transcription,
                                  selection: modelBinding(\.transcriptionModel), apiKey: apiKey)
                OpenAIModelPicker(label: "Chat model", purpose: .chat,
                                  selection: modelBinding(\.chatModel), apiKey: apiKey)
                HStack {
                    Link("Transcription models", destination: transcriptionModelsURL)
                    Spacer()
                    Link("Chat models", destination: chatModelsURL)
                }
                .font(.caption)
                Text("Each model list is refreshed from your OpenAI account when opened. Selection saves automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Link("Create a Desktop OAuth client in browser", destination: googleClientsURL)
                Link("Enable Google Calendar API in browser", destination: googleCalendarAPIURL)
                Text("Select a Google Cloud project, enable the Calendar API, configure the OAuth consent screen, then create a Desktop app client. Copy its ID and secret below.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("OAuth client ID", text: $clientID)
                SecureField("OAuth client secret", text: $clientSecret)
                HStack {
                    Text(app.googleSignedIn ? "Connected" : "Not connected")
                        .foregroundStyle(app.googleSignedIn ? .green : .secondary)
                    Spacer()
                    if app.googleSignedIn {
                        Button("Sign out") { Task { await app.signOut() } }
                    }
                    Button(app.googleSignedIn ? "Sign in again" : "Sign in with Google") {
                        save()
                        signingIn = true
                        Task {
                            message = await app.signIn()
                            signingIn = false
                        }
                    }
                    .disabled(clientID.isEmpty || signingIn)
                }
                Button(checkingCalendar ? "Checking Calendar access…" : "Check Calendar access") {
                    checkingCalendar = true
                    Task {
                        do {
                            _ = try await app.calendar.nearbyEvents(around: Date())
                            calendarCheckMessage = "Google Calendar can be read with this account."
                        } catch let issue as CalendarError {
                            calendarCheckMessage = CreationError(issue, language: .en).localizedDescription
                        } catch {
                            calendarCheckMessage = error.localizedDescription
                        }
                        checkingCalendar = false
                    }
                }
                .disabled(!app.googleSignedIn || checkingCalendar)
                if let calendarCheckMessage {
                    Text(calendarCheckMessage).font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Google Calendar")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set the consent screen to “In production”. The app requests only calendar.events; Google may show an unverified-app warning.")
                    Link("Google's Desktop OAuth setup guide", destination: googleOAuthGuideURL)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Save keys") { save() }.keyboardShortcut(.defaultAction)
            }
            if let message {
                Text(message).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = app.secrets.read(.openAIAPIKey) ?? ""
            clientID = app.secrets.read(.googleClientID) ?? ""
            clientSecret = app.secrets.read(.googleClientSecret) ?? ""
        }
    }

    private func save() {
        do {
            try app.secrets.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .openAIAPIKey)
            try app.secrets.write(clientID.trimmingCharacters(in: .whitespacesAndNewlines), for: .googleClientID)
            try app.secrets.write(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines), for: .googleClientSecret)
            message = "Saved to the Keychain."
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct OpenAIModelPicker: View {
    @Environment(AppCoordinator.self) private var app
    let label: String
    let purpose: OpenAIModelPurpose
    @Binding var selection: String
    let apiKey: String

    @State private var loading = false
    @State private var choices: [String] = []
    @State private var error: String?

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Picker(label, selection: $selection) {
                    ForEach(options, id: \.self) { model in Text(model).tag(model) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 310)
                .accessibilityLabel(label)
                .simultaneousGesture(TapGesture().onEnded { Task { await refresh() } })
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
                .help("Check available models again")
            }
        }
        if loading { ProgressView("Checking available models…").font(.caption) }
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        if !choices.isEmpty && !choices.contains(selection) {
            Text("Current model is unavailable. Choose another from the list.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var options: [String] {
        choices.contains(selection) ? choices : [selection] + choices
    }

    @MainActor
    private func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            let available = try await app.openAI.availableModelIDs(using: apiKey)
            choices = purpose.choices(from: available)
            if choices.isEmpty { error = "No matching models are available for this API key." }
        } catch let issue as AIError {
            switch issue {
            case .missingAPIKey: error = "Add an OpenAI API key above, then open this list again."
            case .invalidAPIKey: error = "This API key was rejected. Check it and try again."
            case .offline: error = "The Mac is offline. Connect to the internet and try again."
            case let .badResponse(detail), let .service(detail): error = "Could not load models: \(detail)"
            }
        } catch {
            self.error = "Could not load models: \(error.localizedDescription)"
        }
        loading = false
    }
}
