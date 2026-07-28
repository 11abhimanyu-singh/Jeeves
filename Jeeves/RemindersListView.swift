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

    private var active: [Reminder] { reminders.filter(\.isActive) }
    private var todayList: [Reminder] { active.filter(firesToday) }
    private var upcomingList: [Reminder] { active.filter { !firesToday($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { openAdd() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 18))
                        Text("New reminder").font(.system(size: 14, weight: .semibold))
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
    }

    // MARK: Sections

    @ViewBuilder
    private func section(_ title: String, _ items: [Reminder], emptyText: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.serif(18)).foregroundStyle(Color.textPrimary)
            if items.isEmpty {
                if let emptyText {
                    Text(emptyText).font(.system(size: 13)).foregroundStyle(Color.textMuted)
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
                Image(systemName: "circle").font(.system(size: 22)).foregroundStyle(Color.textMuted)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(r.title.isEmpty ? "Reminder" : r.title)
                    .font(.serif(16)).foregroundStyle(Color.textPrimary).lineLimit(2)
                HStack(spacing: 7) {
                    Text(timeLabel(r))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentDeep)
                    if r.recurrence != .once {
                        Text(r.recurrence.label.uppercased())
                            .font(.system(size: 9, weight: .bold)).kerning(0.4)
                            .foregroundStyle(Color.sageDeep)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.sage.opacity(0.20)))
                    }
                }
            }
            Spacer(minLength: 6)
            Button { snooze(r) } label: {
                Text("Snooze").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Color.accentDeep)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.textPrimary.opacity(0.06), lineWidth: 1))
    }

    // MARK: Add sheet

    private let timeChips: [(String, Int, Int)] = [("9:00 AM", 9, 0), ("1:30 PM", 13, 30), ("6:00 PM", 18, 0), ("9:00 PM", 21, 0)]

    private var addSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Remind me to…", text: $draftTitle)
                        .font(.system(size: 16)).padding(13)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))

                    Text("WHEN").font(.system(size: 10, weight: .bold)).kerning(1).foregroundStyle(Color.textMuted).padding(.top, 14)
                    chipRow(timeChips.map(\.0)) { i in draftHour == timeChips[i].1 && draftMinute == timeChips[i].2 } pick: { i in
                        draftHour = timeChips[i].1; draftMinute = timeChips[i].2
                    }

                    Text("REPEAT").font(.system(size: 10, weight: .bold)).kerning(1).foregroundStyle(Color.textMuted).padding(.top, 14)
                    chipRow(ReminderRecurrence.allCases.map(\.label)) { i in draftRecurrence == ReminderRecurrence.allCases[i] } pick: { i in
                        draftRecurrence = ReminderRecurrence.allCases[i]
                    }

                    Button { saveReminder() } label: {
                        Text("Add reminder").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
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

    private func chipRow(_ labels: [String], selected: @escaping (Int) -> Bool, pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 7) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                let on = selected(i)
                Button { pick(i) } label: {
                    Text(label).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(on ? Color.accentDeep : Color.textSoft)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Capsule().fill(on ? Color.accent.opacity(0.15) : Color.surface))
                        .overlay(Capsule().stroke(on ? Color.accent : Color.textPrimary.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Helpers + mutations

    private func firesToday(_ r: Reminder) -> Bool {
        let cal = Calendar.current
        switch r.recurrence {
        case .once:     return cal.isDateInToday(r.fireAt)
        case .daily:    return true
        case .weekdays: return (2...6).contains(cal.component(.weekday, from: Date()))
        case .weekly:   return cal.component(.weekday, from: r.fireAt) == cal.component(.weekday, from: Date())
        }
    }

    private func timeLabel(_ r: Reminder) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = (r.recurrence == .once && !Calendar.current.isDateInToday(r.fireAt)) ? "EEE h:mm a" : "h:mm a"
        return f.string(from: r.fireAt)
    }

    private func openAdd() {
        draftTitle = ""; draftHour = 9; draftMinute = 0; draftRecurrence = .once; showAdd = true
    }

    private func saveReminder() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var fire = Calendar.current.date(bySettingHour: draftHour, minute: draftMinute, second: 0, of: Date()) ?? Date()
        // A one-off time already past today rolls to tomorrow, so a fully-specified
        // calendar trigger still has a future fire.
        if draftRecurrence == .once && fire < Date() {
            fire = Calendar.current.date(byAdding: .day, value: 1, to: fire) ?? fire
        }
        modelContext.insert(Reminder(title: title.isEmpty ? "Reminder" : title, fireAt: fire, recurrence: draftRecurrence))
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
