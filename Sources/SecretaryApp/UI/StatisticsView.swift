import SecretaryCore
import SwiftUI

/// Local, durable task history and time spent by project.
struct StatisticsView: View {
    @Environment(AppCoordinator.self) private var app
    @State private var projectName = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            let state = app.store.state
            let allTime = ActivityStatistics.projectTotals(state.projectTimers, now: now)
            let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
            let lastWeek = ActivityStatistics.projectTotals(state.projectTimers, from: weekStart, now: now)
            Form {
                Section("Project timer") {
                    if let active = app.activeProjectTimer {
                        HStack {
                            Label(active.project, systemImage: "timer")
                            Spacer()
                            Text(ActivityStatistics.durationText(active.elapsed(at: now)))
                                .monospacedDigit()
                            Button("Stop") { app.stopProjectTimer() }
                        }
                    } else {
                        Text("No timer is running.").foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Project name", text: $projectName)
                        Button("Start timer") {
                            app.startProjectTimer(projectName)
                            projectName = ""
                        }
                        .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("Time by project") {
                    if allTime.isEmpty {
                        Text("No project time recorded yet.").foregroundStyle(.secondary)
                    }
                    ForEach(allTime, id: \.project) { total in
                        HStack {
                            Text(total.project)
                            Spacer()
                            let week = lastWeek.first { $0.project.localizedCaseInsensitiveCompare(total.project) == .orderedSame }
                            Text("7 days: \(ActivityStatistics.durationText(week?.seconds ?? 0))")
                                .foregroundStyle(.secondary)
                            Text("All: \(ActivityStatistics.durationText(total.seconds))")
                        }
                    }
                }
                Section("Tasks and reminders") {
                    let history = state.activityHistory
                    LabeledContent("Reminders", value: "\(history.filter { $0.kind == .reminder }.count)")
                    LabeledContent("Calendar events", value: "\(history.filter { $0.kind == .calendarEvent }.count)")
                    LabeledContent("Daily check-ins", value: "\(history.filter { $0.kind == .habit }.count)")
                    LabeledContent("Completed check-ins", value: "\(state.completedHabits.count)")
                }
                Section("History") {
                    if state.activityHistory.isEmpty {
                        Text("No tasks or reminders recorded yet.").foregroundStyle(.secondary)
                    }
                    ForEach(state.activityHistory.sorted { $0.createdAt > $1.createdAt }) { entry in
                        HStack {
                            Image(systemName: symbol(for: entry.kind)).frame(width: 20)
                            VStack(alignment: .leading) {
                                Text(entry.title)
                                Text(entry.scheduledAt.formatted(date: .abbreviated, time: .shortened)
                                     + (entry.recurring ? " · repeats" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(label(for: entry.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("History and project time are stored on this Mac. Deleting an upcoming alarm does not erase its history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }

    private func label(for kind: RequestKind) -> String {
        switch kind {
        case .reminder: "Reminder"
        case .habit: "Daily check-in"
        case .calendarEvent: "Calendar event"
        }
    }

    private func symbol(for kind: RequestKind) -> String {
        switch kind {
        case .reminder: "bell"
        case .habit: "checkmark.circle"
        case .calendarEvent: "calendar"
        }
    }
}
