//
//  DeviceCalendarsSheet.swift
//  Jeeves
//
//  Choose which of the phone's calendars Jeeves plans around.
//
//  The account list is not something this app maintains — iOS does. Add an
//  Outlook account in Settings and it appears here, alongside iCloud and
//  anything else, without a line of code changing. That is the whole argument
//  for EventKit over a Graph client.
//
//  Grouped by ACCOUNT rather than shown flat, because "which calendar is
//  Work?" is a question you answer by knowing which mailbox it came from.
//

import SwiftUI

struct DeviceCalendarsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called with the chosen identifiers once saved, so the caller can sync.
    var onSave: (Set<String>) -> Void = { _ in }

    @State private var calendars: [EventKitService.CalendarChoice] = []
    @State private var selected: Set<String> = []
    @State private var accessDenied = false
    @State private var loaded = false

    private var accounts: [String] {
        Array(Set(calendars.map(\.account))).sorted()
    }
    private func inAccount(_ account: String) -> [EventKitService.CalendarChoice] {
        calendars.filter { $0.account == account }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.textPrimary.opacity(0.22))
                .frame(width: 36, height: 4.5).padding(.top, 8).padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 6) {
                Text("Calendars on this phone").font(.serif(19)).foregroundStyle(Color.textPrimary)
                Text(subtitle).font(.ui(13)).foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)

            if accessDenied {
                deniedNotice
            } else if calendars.isEmpty {
                emptyNotice
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(accounts, id: \.self) { account in
                            accountSection(account)
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 8)
                }
                .padding(.top, 8)
            }

            footer
        }
        .background(Color.bg)
        .presentationDetents([.large])
        .task { await load() }
    }

    private var subtitle: String {
        accessDenied
            ? "Jeeves doesn't have calendar access yet."
            : "Tick the ones that are real commitments. Everything ticked becomes an anchor your day is planned around."
    }

    private func accountSection(_ account: String) -> some View {
        VStack(spacing: 0) {
            Text(account.uppercased())
                .font(.ui(11, weight: .semibold)).kerning(0.6)
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16).padding(.bottom, 4)
            ForEach(inAccount(account)) { cal in
                row(cal)
                if cal.id != inAccount(account).last?.id {
                    Divider().overlay(Color.textPrimary.opacity(0.08))
                }
            }
        }
    }

    private func row(_ cal: EventKitService.CalendarChoice) -> some View {
        Button {
            if selected.contains(cal.id) { selected.remove(cal.id) } else { selected.insert(cal.id) }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: selected.contains(cal.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(selected.contains(cal.id) ? Color.accent : Color.textMuted.opacity(0.7))
                Text(cal.title).font(.ui(14))
                    .foregroundStyle(selected.contains(cal.id) ? Color.textPrimary : Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
            }
            .padding(.vertical, 11).frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var deniedNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendar access is off")
                .font(.ui(14, weight: .semibold)).foregroundStyle(Color.textPrimary)
            Text("Turn it on in iOS Settings → Privacy & Security → Calendars → Jeeves, then come back.")
                .font(.ui(13)).foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    /// Access granted and still nothing to show means the phone itself has no
    /// calendar accounts — the fix is in iOS Settings, not here.
    private var emptyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No calendars on this phone yet")
                .font(.ui(14, weight: .semibold)).foregroundStyle(Color.textPrimary)
            Text("Add your accounts in iOS Settings → Apps → Calendar → Accounts. Outlook, Google and iCloud all appear here once they're added, and Jeeves reads whichever you tick.")
                .font(.ui(13)).foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button { save() } label: {
                Text(saveLabel)
                    .font(.ui(15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(RoundedRectangle(cornerRadius: 13)
                        .fill(calendars.isEmpty ? Color.textMuted.opacity(0.35) : Color.accent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(calendars.isEmpty)

            Button { dismiss() } label: {
                Text("Not now").font(.ui(13.5)).foregroundStyle(Color.textMuted)
                    .frame(minHeight: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.bottom, 12).padding(.top, 8)
    }

    private var saveLabel: String {
        if selected.isEmpty { return "Use every calendar" }
        return "Use \(selected.count) calendar\(selected.count == 1 ? "" : "s")"
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        let granted = await EventKitService.requestAccess()
        guard granted else { accessDenied = true; return }
        calendars = EventKitService.calendars()
        let stored = EventKitService.selectedCalendarIDs
        // No stored choice means every calendar — so show them all ticked
        // rather than none, which would read as "nothing is connected".
        selected = stored.isEmpty ? Set(calendars.map(\.id)) : stored
    }

    private func save() {
        // Everything ticked is stored as "no filter", so a calendar added to
        // the phone next month is included instead of silently missing.
        let all = Set(calendars.map(\.id))
        let toStore = (selected == all) ? [] : selected
        EventKitService.selectedCalendarIDs = toStore
        EventKitService.isEnabled = true
        onSave(toStore)
        dismiss()
    }
}
