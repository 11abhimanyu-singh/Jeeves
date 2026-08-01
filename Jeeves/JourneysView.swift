//
//  JourneysView.swift
//  Jeeves
//
//  Every journey in one place, and a way to remove them.
//
//  Journeys were the one travel entity with no screen of their own: you could
//  see a leg on the day it happened, but never the whole list, and chat could
//  only delete one named leg from one named trip at a time. "Delete all
//  journeys of August and September" had no answer — which is exactly the
//  question a user asks after clearing out trips.
//
//  Deleting here cancels the leave-by nudge too. A journey whose reminder
//  outlives it is the failure this feature exists to prevent, pointed the
//  wrong way.
//

import SwiftUI
import SwiftData

struct JourneysView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var segments: [TravelSegment]
    @Query private var trips: [Trip]

    @State private var selection: Set<UUID> = []
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var receipt: String?

    /// Journeys grouped under their trip, newest trip last, legs in day order.
    /// A journey whose trip is gone gets its own group — those are orphans and
    /// worth seeing rather than hiding.
    private var groups: [(title: String, subtitle: String, legs: [TravelSegment])] {
        let byTrip = Dictionary(grouping: segments, by: \.tripID)
        var out: [(String, String, [TravelSegment])] = []
        for (tripID, legs) in byTrip {
            let sorted = legs.sorted { $0.day < $1.day }
            if let trip = trips.first(where: { $0.id == tripID }) {
                out.append((trip.title.isEmpty ? "Trip" : trip.title,
                            TravelGuard.dayRange(trip), sorted))
            } else {
                out.append(("Orphaned", "their trip no longer exists", sorted))
            }
        }
        return out.sorted { ($0.2.first?.day ?? .distantPast) < ($1.2.first?.day ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if segments.isEmpty { emptyState } else { list }
            }
            .background(Color.bg)
            .navigationTitle("Journeys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !segments.isEmpty {
                        Button(editing ? "Done" : "Select") {
                            editing.toggle()
                            if !editing { selection.removeAll() }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if editing && !selection.isEmpty { deleteBar }
            }
            .confirmationDialog("Delete \(selection.count) journey\(selection.count == 1 ? "" : "s")?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete \(selection.count)", role: .destructive) { deleteSelected() }
                Button("Keep them", role: .cancel) {}
            } message: {
                Text("Their leave-by reminders are cancelled too. The trips themselves stay.")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "airplane.departure")
                .font(.ui(30)).foregroundStyle(Color.textMuted)
            Text("No journeys").font(Font.serif(17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("Flights and drives you add to a trip show up here.")
                .font(.ui(13)).foregroundStyle(Color.textSoft)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let receipt {
                    Text(receipt)
                        .font(.ui(12.5)).foregroundStyle(Color.sageDeep)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.sageLight))
                }
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(group.title.uppercased())
                                .font(.ui(11, weight: .bold)).kerning(0.9)
                                .foregroundStyle(Color.accentDeep)
                            Text(group.subtitle)
                                .font(.ui(11)).foregroundStyle(Color.textMuted)
                        }
                        ForEach(group.legs, id: \.id) { leg in row(leg) }
                    }
                }
            }
            .padding(20)
        }
    }

    private func row(_ leg: TravelSegment) -> some View {
        let selected = selection.contains(leg.id)
        return Button {
            guard editing else { return }
            if selected { selection.remove(leg.id) } else { selection.insert(leg.id) }
        } label: {
            HStack(spacing: 12) {
                if editing {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.ui(19))
                        .foregroundStyle(selected ? Color.accent : Color.textMuted)
                }
                Image(systemName: leg.mode == .drive ? "car.fill" : "airplane")
                    .font(.ui(14)).foregroundStyle(Color.textSoft).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(leg.label.isEmpty ? leg.mode.label : leg.label)
                        .font(Font.serif(15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(subtitleFor(leg))
                        .font(.ui(11.5)).foregroundStyle(Color.textMuted)
                }
                Spacer()
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 15)
                .fill(selected ? Color.sageLight : Color.surface))
        }
        .buttonStyle(.plain)
    }

    /// "Sat 2 Aug · leave 06:47 · 2h 43m" — and says plainly when a leg has no
    /// measurement rather than showing a confident zero.
    private func subtitleFor(_ leg: TravelSegment) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"
        var parts = [f.string(from: leg.day)]
        if let plan = LeaveBy.plan(for: leg) {
            parts.append("leave \(TravelClock.hhmm(plan.leaveAt, in: leg.fromTimeZone))")
        }
        parts.append(leg.travelMinutes > 0
                     ? StayWindow.hhmm(leg.travelMinutes)
                     : "not measured")
        return parts.joined(separator: " · ")
    }

    private var deleteBar: some View {
        Button { confirmDelete = true } label: {
            Text("Delete \(selection.count) journey\(selection.count == 1 ? "" : "s")")
                .font(.ui(14.5, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentDeep))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20).padding(.bottom, 10)
        .background(Color.bg)
    }

    private func deleteSelected() {
        let going = segments.filter { selection.contains($0.id) }
        guard !going.isEmpty else { return }
        let names = going.map { $0.label.isEmpty ? $0.mode.label : $0.label }
        for leg in going {
            TravelNotifier.cancel(segment: leg)
            EventLog.log(.nudgeCancelled,
                         "\(leg.label.isEmpty ? leg.mode.label : leg.label) deleted from the journeys list",
                         subject: leg.id, context: modelContext)
            modelContext.delete(leg)
        }
        modelContext.saveOrLog("journeys.delete")
        receipt = "Deleted \(going.count) journey\(going.count == 1 ? "" : "s") and cancelled their reminders: "
            + names.joined(separator: ", ") + "."
        selection.removeAll()
        editing = false
    }
}
