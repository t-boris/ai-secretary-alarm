import Foundation

/// Texts assembled from local data only, so alarms work offline (DEC-016).
public enum SpokenText {
    static func time(_ date: Date, zone: TimeZone, language: SpeechLanguage) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: language == .ru ? "ru_RU" : "en_US")
        f.timeZone = zone
        f.dateFormat = language == .ru ? "HH:mm" : "h:mm a"
        return f.string(from: date)
    }

    static func dateTime(_ date: Date, zone: TimeZone, language: SpeechLanguage) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: language == .ru ? "ru_RU" : "en_US")
        f.timeZone = zone
        f.dateFormat = language == .ru ? "EEEE, d MMMM, HH:mm" : "EEEE, MMMM d, h:mm a"
        return f.string(from: date)
    }

    static func minutes(_ seconds: TimeInterval) -> Int { max(1, Int((seconds / 60).rounded())) }

    static func placeLabel(_ place: ResolvedPlace?) -> String? {
        guard let place else { return nil }
        return place.name ?? place.address
    }

    public static func alarm(for r: PlannedReminder, record: EventRecord, settings: AppSettings, zone: TimeZone) -> AlarmContent {
        let ru = record.language == .ru
        let occ = r.occurrence
        let at = time(occ.start, zone: zone, language: record.language)
        let place = placeLabel(occ.place)
        let travel = r.travelSeconds.map(minutes) ?? 0
        var sentences: [String]
        let heading: String
        if record.isStandaloneReminder {
            heading = record.isHabit ? (ru ? "Ежедневная проверка" : "Daily check-in")
                                     : (ru ? "Напоминание" : "Reminder")
            sentences = [record.isHabit
                ? (ru ? "Ежедневная проверка: \(occ.title). Отметьте, когда выполните." : "Daily check-in: \(occ.title). Mark it done when you finish.")
                : (ru ? "Напоминание: \(occ.title)." : "Reminder: \(occ.title).")]
        } else { switch r.kind {
        case .standard:
            heading = ru ? "Напоминание" : "Reminder"
            sentences = [ru ? "Напоминание. \(occ.title) в \(at)." : "Reminder. \(occ.title) at \(at)."]
        case .getReady:
            heading = ru ? "Пора собираться" : "Time to get ready"
            let where_ = place.map { ru ? ", \($0)" : " at \($0)" } ?? ""
            sentences = [
                ru ? "Пора собираться. \(occ.title) в \(at)\(where_)." : "Time to get ready. \(occ.title) at \(at)\(where_).",
                ru ? "Выходить через \(r.prepMinutes) мин., дорога займёт около \(travel) мин."
                   : "Leave in \(r.prepMinutes) minutes; the trip takes about \(travel) minutes.",
            ]
        case .leaveNow:
            heading = ru ? "Пора выходить" : "Time to leave"
            let where_ = place.map { ru ? ", \($0)" : " at \($0)" } ?? ""
            sentences = [
                ru ? "Пора выходить. \(occ.title) в \(at)\(where_)." : "Time to leave now. \(occ.title) at \(at)\(where_).",
                ru ? "Дорога займёт около \(travel) мин." : "The trip takes about \(travel) minutes.",
            ]
        }
        }
        if r.usedFallbackBuffer {
            sentences.append(ru
                ? "Не удалось рассчитать время в пути, поэтому использован запас по умолчанию — \(settings.fallbackBufferMinutes) мин."
                : "I couldn't get a travel estimate, so I used the default buffer of \(settings.fallbackBufferMinutes) minutes.")
        }
        if let hint = occ.prepHint, !hint.isEmpty { sentences.append(hint) }
        let text = sentences.joined(separator: " ")
        return AlarmContent(reminderKey: r.key, eventID: record.id, kind: r.kind, heading: "\(heading): \(occ.title)",
                            body: text, spokenText: text,
                            soundID: record.alarmSoundID ?? settings.alarmSound(for: record.eventType),
                            language: record.language)
    }

    /// Confirmation summary lines (DEC-015): title, date/time with zone, recurrence, location, reminders,
    /// hint, origin, place-save question.
    public static func summary(for draft: EventDraft, reminders: [PlannedReminder], skippedGetReady: Bool,
                               originLabel: String?, localZone: TimeZone) -> [String] {
        let lang = draft.language
        let ru = lang == .ru
        let zone = TimeZone(identifier: draft.timeZoneID) ?? localZone
        var when = dateTime(draft.start, zone: zone, language: lang) + " (\(draft.timeZoneID))"
        if zone.secondsFromGMT(for: draft.start) != localZone.secondsFromGMT(for: draft.start) {
            when += ru ? "; у вас \(time(draft.start, zone: localZone, language: lang))"
                       : "; your time \(time(draft.start, zone: localZone, language: lang))"
        }
        var lines = [draft.title, when]
        if draft.kind != .calendarEvent {
            if let rec = draft.recurrence { lines.append(recurrenceText(rec, language: lang)) }
            lines.append(draft.kind == .habit
                ? (ru ? "Ежедневная проверка в \(time(draft.start, zone: localZone, language: lang))"
                      : "Daily check-in at \(time(draft.start, zone: localZone, language: lang))")
                : (ru ? "Локальное напоминание в \(time(draft.start, zone: localZone, language: lang))"
                      : "Local reminder at \(time(draft.start, zone: localZone, language: lang))"))
            return lines
        }
        if let rec = draft.recurrence { lines.append(recurrenceText(rec, language: lang)) }
        switch draft.locationType {
        case .home: lines.append(ru ? "Место: дома" : "Location: home")
        case .noLocation: lines.append(ru ? "Без места / онлайн" : "No location / online")
        case .offSite:
            let label = draft.place.map { p in [p.name, p.address].compactMap { $0 }.joined(separator: ", ") }
            lines.append((ru ? "Место: " : "Location: ") + (label ?? (ru ? "адрес не найден" : "address not found")))
        }
        for r in reminders {
            let t = time(r.fireDate, zone: localZone, language: lang)
            switch r.kind {
            case .standard: lines.append(ru ? "Напоминание в \(t)" : "Reminder at \(t)")
            case .getReady: lines.append(ru ? "«Пора собираться» в \(t)" : "'Get ready' at \(t)")
            case .leaveNow:
                var line = ru ? "«Пора выходить» в \(t)" : "'Leave now' at \(t)"
                if r.usedFallbackBuffer {
                    line += ru ? " (время в пути неизвестно, запас по умолчанию)" : " (no travel estimate, default buffer)"
                }
                lines.append(line)
            }
        }
        if skippedGetReady {
            lines.append(ru ? "Время «пора собираться» уже прошло — будет только «пора выходить»."
                            : "The 'get ready' time has already passed; only 'leave now' is scheduled.")
        }
        if let hint = draft.prepHint, !hint.isEmpty { lines.append((ru ? "Подготовка: " : "Preparation: ") + hint) }
        if draft.locationType == .offSite, let originLabel {
            lines.append((ru ? "Откуда: " : "From: ") + originLabel)
        }
        if let name = draft.newPlaceName, draft.savePlace {
            lines.append(ru ? "Сохранить место «\(name)»?" : "Save as '\(name)'?")
        }
        lines.append(ru ? "Создать событие? Скажите «да», исправьте или отмените."
                        : "Create this event? Say 'yes', correct something, or cancel.")
        return lines
    }

    static func recurrenceText(_ r: Recurrence, language: SpeechLanguage) -> String {
        let ru = language == .ru
        let names: [Weekday: (String, String)] = [
            .MO: ("пн", "Mon"), .TU: ("вт", "Tue"), .WE: ("ср", "Wed"), .TH: ("чт", "Thu"),
            .FR: ("пт", "Fri"), .SA: ("сб", "Sat"), .SU: ("вс", "Sun"),
        ]
        let days = r.byWeekday.compactMap { names[$0].map { ru ? $0.0 : $0.1 } }.joined(separator: "/")
        let every = r.interval > 1 ? (ru ? "каждые \(r.interval) " : "every \(r.interval) ") : (ru ? "каждый " : "every ")
        switch r.frequency {
        case .daily: return ru ? (r.interval > 1 ? "Повтор: каждые \(r.interval) дн." : "Повтор: каждый день")
                               : (r.interval > 1 ? "Repeats every \(r.interval) days" : "Repeats daily")
        case .weekly:
            let unit = ru ? (r.interval > 1 ? "нед." : "неделю") : (r.interval > 1 ? "weeks" : "week")
            return (ru ? "Повтор: " : "Repeats ") + every + unit + (days.isEmpty ? "" : " (\(days))")
        case .monthly: return ru ? "Повтор: ежемесячно" : "Repeats monthly"
        case .yearly: return ru ? "Повтор: ежегодно" : "Repeats yearly"
        }
    }
}
