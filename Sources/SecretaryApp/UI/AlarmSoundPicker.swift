import SecretaryCore
import SwiftUI

/// A system picker for built-in melodies and imported personal audio.
struct AlarmSoundPicker: View {
    let label: String
    @Binding var selection: String
    var allowsTypeDefault = false

    @State private var refresh = 0
    @State private var error: String?

    var body: some View {
        HStack {
            Picker(label, selection: $selection) {
                if allowsTypeDefault { Text("Use event type sound").tag("") }
                ForEach(AlarmSoundLibrary.options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            Button("Import audio…") {
                do {
                    if let id = try AlarmSoundLibrary.importAudio() {
                        refresh += 1
                        selection = id
                        error = nil
                    }
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .id(refresh)
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
    }
}
