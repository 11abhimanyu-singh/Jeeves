//
//  RemindersListView.swift
//  Jeeves
//
//  The reminders list — timed nudges grouped into Today / Upcoming, each with a
//  tap-circle to complete, its time, a recurrence badge, and a Snooze. A "+"
//  opens a sheet to schedule a new one (title · time chips · repeat chips). Any
//  mutation reschedules the underlying local notifications so pending fires
//  always match the store. Warm editorial styling; self-contained.
//

import SwiftUI
import SwiftData

struct RemindersListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Reminder.fireAt) private var reminders: [Reminder]

    @State private var showAdd = false
    @State private var draftTitle = ""
    @State private var draftHour = 9
    @State private var draftMinute = 0
    @State private var draftRecurrence: ReminderRecurrence = .once
    /// The day a one-off lands on, and the anchor a Weekly repeats from. The
    /// sheet used to build `fireAt` from `Date()` with no way to say otherwise,
    /// so the only expressible one-offs were four times today and the same four
    /// tomorrow — eight in total.
    @State private var draftDate = Date()
    /// Set when the user picks a time the four chips don't offer.
    @State private var showTimePicker = false
    /// Days between fires for an "Every…" reminder.
    @State private var draftInterval = 2

    /// The next three real dates an "Every…" draft would land on — the same
    /// arithmetic the scheduler runs, so the preview cannot promise a day the
    /// notification won't arrive on.
    private var nextThree: String {
        let dates = ReminderRecurrence.everyNDays.occurrences(
            anchor: RemindersListView.fireDate(day: draftDate, hour: draftHour,
                                               minute: draftMinute, recurrence: .everyNDays),
            intervalDays: draftInterval, count: 3)
        guard !dates.isEmpty else { return "" }
        return dates.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
            .joined(separator: " · ")
    }
    @State private var editing: Reminder?
    @State private var undoable: UndoableDelete?

    private var active: [Reminder] { reminders.filter(\.isActive) }
    private var todayList: [Reminder] { active.filter(firesToday) }
    private var upcomingList: [Reminder] { active.filter { !firesToday($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { openAdd() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus.circle.fill").font(.ui(18))
                        Text("New reminder").font(.ui(14, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color.accentDeep)
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)

                section("Today", todayList, emptyText: "Nothing left today.")
                if !upcomingList.isEmpty { section("Upcoming", upcomingList, emptyText: nil) }
            }
            .padding(20)
        }
        .background(Color.bg)
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: $editing) { ReminderEditSheet(reminder: $0, onSaved: rescheduleAll) }
        .safeAreaInset(edge: .bottom) {
            UndoBanner(pending: $undoable)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .animation(.easeInOut(duration: 0.18), value: undoable?.id)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func section(_ title: String, _ items: [Reminder], emptyText: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.serif(18)).foregroundStyle(Color.textPrimary)
            if items.isEmpty {
                if let emptyText {
                    Text(emptyText).font(.ui(13)).foregroundStyle(Color.textMuted)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
                }
            } else {
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ r: Reminder) -> some View {
        HStack(spacing: 12) {
            Button { complete(r) } label: {
                Image(systemName: "circle").font(.ui(22)).foregroundStyle(Color.textMuted)
            }
            .buttonStyle(.plain)

            // Tapping the body opens the editor — typos and wrong times get
            // fixed in place, not deleted and retyped.
            Button { editing = r } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.title.isEmpty ? "Reminder" : r.title)
                            .font(.serif(16)).foregroundStyle(Color.textPrimary).lineLimit(2)
                        HStack(spacing: 7) {
                            Text(timeLabel(r))
                                .font(.ui(12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.accentDeep)
                            if r.recurrence != .once {
                                Text(r.recurrence.label.uppercased())
                                    .font(.ui(9, weight: .bold)).kerning(0.4)
                                    .foregroundStyle(Color.sageDeep)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.sage.opacity(0.20)))
                            }
                        }
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { snooze(r) } label: {
                Text("Snooze").font(.ui(11.5, weight: .bold)).foregroundStyle(Color.accentDeep)
            }
            .buttonStyle(.plain)
            Button { delete(r) } label: {
                Image(systemName: "trash")
                    .font(.ui(13))
                    .foregroundStyle(Color.textMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Delete \(r.title)")
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.textPrimary.opacity(0.06), lineWidth: 1))
    }

    /// Remove a reminder entirely — and its pending notification with it.
    /// Undo rather than confirm — this trash sits directly beside "Snooze",
    /// the tightest and riskiest adjacency in the app. Restoring keeps the
    /// original id so the rescheduled notification matches the old one.
    private func delete(_ r: Reminder) {
        // intervalDays travels with it, or undoing an "Every 3 days" reminder
        // quietly restores it as every 2.
        let restored = Reminder(id: r.id, title: r.title, fireAt: r.fireAt,
                                recurrence: r.recurrence, enabled: r.enabled,
                                completedAt: r.completedAt, intervalDays: r.intervalDays)
        let title = r.title
        modelContext.delete(r)
        modelContext.saveOrLog()
        rescheduleAll()
        undoable = UndoableDelete(label: title.isEmpty ? "Reminder deleted" : "Deleted \u{201C}\(title)\u{201D}") {
            modelContext.insert(restored)
            modelContext.saveOrLog()
            rescheduleAll()
        }
    }

    // MARK: Add sheet

    private let timeChips: [(String, Int, Int)] = [("9:00 AM", 9, 0), ("1:30 PM", 13, 30), ("6:00 PM", 18, 0), ("9:00 PM", 21, 0)]

    private var addSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Remind me to…", text: $draftTitle)
                        .font(.ui(16)).padding(13)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))

                    Text("WHEN").font(.ui(10, weight: .bold)).kerning(1).foregroundStyle(Color.textMuted).padding(.top, 14)
                    chipRow(timeChips.map(\.0) + ["Other…"]) { i in
                        i == timeChips.count
                            ? !timeChips.contains { $0.1 == draftHour && $0.2 == draftMinute }
                            : draftHour == timeChips[i].1 && draftMinute == timeChips[i].2
                    } pick: { i in
                        if i == timeChips.count { showTimePicker = true }
                        else { draftHour = timeChips[i].1; draftMinute = timeChips[i].2; showTimePicker = false }
                    }
                    // The four chips stay as shortcuts — they cover most of what
                    // gets typed — but they are no longer the whole vocabulary.
                    if showTimePicker || !timeChips.contains(where: { $0.1 == draftHour && $0.2 == draftMinute }) {
                        DatePicker("", selection: draftTimeBinding, displayedComponents: [.hourAndMinute])
                            .labelsHidden().padding(.top, 6)
                    }

                    Text("REPEAT").font(.ui(10, weight: .bold)).kerning(1).foregroundStyle(Color.textMuted).padding(.top, 14)
                    chipRow(ReminderRecurrence.allCases.map(\.label)) { i in draftRecurrence == ReminderRecurrence.allCases[i] } pick: { i in
                        draftRecurrence = ReminderRecurrence.allCases[i]
                    }

                    // "Every…" is meaningless without its number, and a number
                    // is meaningless without seeing where it lands — a stepper
                    // reading "3" tells you nothing about whether that suits
                    // you, so the next three real dates sit under it.
                    if draftRecurrence.needsInterval {
                        Stepper("Every \(draftInterval) day\(draftInterval == 1 ? "" : "s")",
                                value: $draftInterval, in: 1...90)
                            .font(.ui(14)).padding(.top, 10)
                        Text(nextThree)
                            .font(.ui(12.5)).foregroundStyle(Color.textSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // A one-off needs to say WHICH DAY; a weekly needs to say
                    // which weekday, which it used to take silently from the day
                    // you happened to create it on. Both are the same picker —
                    // the label changes because the question does.
                    if draftRecurrence == .once || draftRecurrence == .weekly {
                        Text(draftRecurrence == .once ? "ON" : "REPEATS ON")
                            .font(.ui(10, weight: .bold)).kerning(1)
                            .foregroundStyle(Color.textMuted).padding(.top, 14)
                        DatePicker("", selection: $draftDate,
                                   in: draftRecurrence == .once ? Date().startOfDay... : Date.distantPast...,
                                   displayedComponents: [.date])
                            .labelsHidden()
                        if draftRecurrence == .weekly {
                            Text("Every \(draftDate.formatted(.dateTime.weekday(.wide)))")
                                .font(.ui(12.5)).foregroundStyle(Color.textSoft)
                        }
                    }

                    Button { saveReminder() } label: {
                        Text("Add reminder").font(.ui(15, weight: .bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(13)
                            .background(RoundedRectangle(cornerRadius: 13).fill(Color.accent))
                    }
                    .buttonStyle(.plain).padding(.top, 18)
                }
                .padding(20)
            }
            .background(Color.bg)
            .navigationTitle("New reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAdd = false } } }
        }
    }

    private func chipRow(_ labels: [String], selected: @escaping (Int) -> Bool,
                         pick: @escaping (Int) -> Void) -> some View {
        ChipScrollRow(labels: labels, selected: selected, pick: pick)
    }

    // MARK: Helpers + mutations

    private func firesToday(_ r: Reminder) -> Bool {
        let cal = Calendar.current
        switch r.recurrence {
        case .once:     return cal.isDateInToday(r.fireAt)
        case .daily:    return true
        case .weekdays: return (2...6).contains(cal.component(.weekday, from: Date()))
        case .weekly:   return cal.component(.weekday, from: r.fireAt) == cal.component(.weekday, from: Date())
        case .everyNDays:
            // Same arithmetic the scheduler uses, so the list and the
            // notifications cannot disagree about which days it lands on.
            return r.recurrence
                .occurrences(anchor: r.fireAt, intervalDays: r.intervalDays, count: 1, cal: cal)
                .first
                .map { cal.isDateInToday($0) } ?? false
        }
    }

    private func timeLabel(_ r: Reminder) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = (r.recurrence == .once && !Calendar.current.isDateInToday(r.fireAt)) ? "EEE h:mm a" : "h:mm a"
        return f.string(from: r.fireAt)
    }

    private func openAdd() {
        draftTitle = ""; draftHour = 9; draftMinute = 0; draftRecurrence = .once
        draftDate = Date(); showTimePicker = false; draftInterval = 2; showAdd = true
    }

    /// Reads and writes the draft time through the same hour/minute the chips
    /// set, so picking "Other…" and picking a chip stay one value.
    private var draftTimeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: draftHour, minute: draftMinute, second: 0, of: Date()) ?? Date() },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                draftHour = c.hour ?? 9; draftMinute = c.minute ?? 0
            })
    }

    /// The fire date a draft describes. Pure and static so the rule is tested
    /// rather than trusted — it used to be three lines inline that pinned every
    /// reminder to `Date()`.
    static func fireDate(day: Date, hour: Int, minute: Int,
                         recurrence: ReminderRecurrence, now: Date = Date(),
                         cal: Calendar = .current) -> Date {
        let base = recurrence == .once ? day : now
        var fire = cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        // A one-off whose moment has already gone rolls forward a day, so a
        // fully-specified calendar trigger still has a future fire. Only when
        // the chosen DAY is today — picking a past date deliberately is the
        // one thing the old sheet could not do, and rolling it would undo that.
        if recurrence == .once, fire <= now, cal.isDate(base, inSameDayAs: now) {
            fire = cal.date(byAdding: .day, value: 1, to: fire) ?? fire
        }
        // Weekly repeats on the weekday of `fireAt`, which the scheduler reads
        // straight off it — so the anchor has to BE the day the user chose.
        if recurrence == .weekly {
            fire = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? fire
        }
        return fire
    }

    private func saveReminder() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let fire = Self.fireDate(day: draftDate, hour: draftHour, minute: draftMinute,
                                 recurrence: draftRecurrence)
        modelContext.insert(Reminder(title: title.isEmpty ? "Reminder" : title, fireAt: fire,
                                     recurrence: draftRecurrence, intervalDays: draftInterval))
        modelContext.saveOrLog()
        showAdd = false
        rescheduleAll()
    }

    private func complete(_ r: Reminder) {
        r.completedAt = Date()
        modelContext.saveOrLog()
        rescheduleAll()
    }

    private func snooze(_ r: Reminder) {
        if r.recurrence == .once {
            r.fireAt = Date().addingTimeInterval(10 * 60)   // just delay it; still one-off
        } else {
            // Don't overwrite the recurrence (that would destroy a daily/weekly
            // schedule) — add a separate one-off 10-minute nudge alongside it.
            modelContext.insert(Reminder(title: r.title, fireAt: Date().addingTimeInterval(10 * 60), recurrence: .once))
        }
        modelContext.saveOrLog()
        rescheduleAll()
    }

    /// Reschedule from a FRESH fetch — the @Query array isn't updated synchronously
    /// within a mutation, so a just-inserted reminder would otherwise be missed.
    private func rescheduleAll() {
        let all = (try? modelContext.fetch(FetchDescriptor<Reminder>())) ?? []
        ReminderScheduler.reschedule(all)
    }
}

// MARK: - Edit sheet

/// Tap a reminder to fix it in place — title, exact time, repeat — and its
/// notification reschedules on save.
struct ReminderEditSheet: View {
    let reminder: Reminder
    var onSaved: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var fireAt = Date()
    @State private var recurrence: ReminderRecurrence = .once
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Remind me to…", text: $title)
                        .font(.ui(16)).padding(13)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))

                    Text("WHEN").font(.ui(10, weight: .bold)).kerning(1)
                        .foregroundStyle(Color.textMuted).padding(.top, 14)
                    // A full picker, not just chips: fixing "18:00" to "18:30"
                    // is exactly the edit this sheet exists for.
                    DatePicker("", selection: $fireAt,
                               displayedComponents: recurrence == .once
                               ? [.date, .hourAndMinute] : [.hourAndMinute])
                        .labelsHidden()
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))

                    Text("REPEAT").font(.ui(10, weight: .bold)).kerning(1)
                        .foregroundStyle(Color.textMuted).padding(.top, 14)
                    // The same component the add sheet uses. This row was a
                    // hand-copied duplicate of it, which is why the fifth
                    // recurrence broke both screens and fixing one would have
                    // left the other reading "Weekda / ys".
                    ChipScrollRow(labels: ReminderRecurrence.allCases.map(\.label),
                                  selected: { ReminderRecurrence.allCases[$0] == recurrence },
                                  pick: { recurrence = ReminderRecurrence.allCases[$0] })
                }
                .padding(20)
            }
            .background(Color.bg)
            .navigationTitle("Edit reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.tint(Color.accentDeep)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        title = reminder.title
        fireAt = reminder.fireAt
        recurrence = reminder.recurrence
    }

    private func save() {
        reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.recurrenceRaw = recurrence.rawValue
        var fire = fireAt
        // A one-off edited to a moment already past rolls forward a day, so
        // the notification always has a future fire.
        if recurrence == .once && fire < Date() {
            fire = Calendar.current.date(byAdding: .day, value: 1, to: fire) ?? fire
        }
        reminder.fireAt = fire
        modelContext.saveOrLog("ReminderEditSheet.save")
        onSaved()
        dismiss()
    }
}


/// Chips that never break a word.
///
/// This started as a plain HStack sized for four, hand-copied into the edit
/// sheet. A fifth repeat option ("Every…") and a fifth time option ("Other…")
/// each pushed it past the width, and SwiftUI's answer to a too-narrow button
/// is to wrap its label — so both sheets read "Weekda / ys", "Weekl / y",
/// "Every / …".
///
/// It scrolls horizontally now, and it is ONE component rather than two
/// copies. A row that can always take one more chip is the only version that
/// survives the next option being added, a larger Dynamic Type setting, or a
/// longer word in another language. `lineLimit(1)` with `fixedSize()` is the
/// guarantee that nothing wraps; the scroll is what keeps it reachable.
struct ChipScrollRow: View {
    let labels: [String]
    let selected: (Int) -> Bool
    let pick: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                    let on = selected(i)
                    Button { pick(i) } label: {
                        Text(label).font(.ui(12.5, weight: .semibold))
                            .lineLimit(1).fixedSize()
                            .foregroundStyle(on ? Color.accentDeep : Color.textSoft)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Capsule().fill(on ? Color.accent.opacity(0.15) : Color.surface))
                            .overlay(Capsule().stroke(on ? Color.accent : Color.textPrimary.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 1)   // room for the capsule stroke
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
