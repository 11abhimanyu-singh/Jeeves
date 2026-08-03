//
//  CatchUpSheet.swift
//  Jeeves
//
//  One prompt for the whole day, not one per block.
//
//  "Leave them unknown" is a real option, not a polite dismissal. If you
//  genuinely can't remember, an honest gap beats a guess — the whole adherence
//  screen is built on keeping those two apart.
//

import SwiftUI
import SwiftData

struct CatchUpSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let pending: [CatchUp.Pending]
    var onFinished: () -> Void = {}

    /// blockKey → did it happen. Absent = still unanswered, which is what
    /// "leave them unknown" preserves.
    @State private var answers: [String: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.textPrimary.opacity(0.22))
                .frame(width: 36, height: 4.5).padding(.top, 8).padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 6) {
                Text(headline).font(.serif(19)).foregroundStyle(Color.textPrimary)
                Text(explanation).font(.ui(13)).foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(pending) { item in
                        row(item)
                        if item.id != pending.last?.id {
                            Divider().overlay(Color.textPrimary.opacity(0.08))
                        }
                    }
                }
                .padding(.horizontal, 18)
            }
            .padding(.top, 14)

            VStack(spacing: 10) {
                Button { save() } label: {
                    Text(answers.isEmpty ? "Save" : "Save \(answers.count) answer\(answers.count == 1 ? "" : "s")")
                        .font(.ui(15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(RoundedRectangle(cornerRadius: 13)
                            .fill(answers.isEmpty ? Color.textMuted.opacity(0.35) : Color.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(answers.isEmpty)

                Button {
                    // An honest gap beats a guess.
                    CatchUp.markAsked()
                    onFinished(); dismiss()
                } label: {
                    Text("Leave them unknown")
                        .font(.ui(13.5)).foregroundStyle(Color.textMuted)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.bottom, 12)
        }
        .background(Color.bg)
        .presentationDetents([.medium, .large])
    }

    private var headline: String {
        let days = Set(pending.map { $0.day.startOfDay })
        if days.count == 1, let day = days.first {
            return Calendar.current.isDateInToday(day) ? "Today has gaps" : "\(Self.dayName(day)) stalled"
        }
        return "A few blocks went unanswered"
    }

    private var explanation: String {
        let stalled = pending.filter { $0.reason == .neverAsked }.count
        let closed = pending.filter { $0.reason == .closedItself }.count
        var parts: [String] = []
        if stalled > 0 { parts.append("\(stalled) never got a notification — a session was left running") }
        if closed > 0 { parts.append("\(closed) closed \(closed == 1 ? "itself" : "themselves") without a duration") }
        return parts.joined(separator: ", ") + ". Worth a minute before the window closes tonight."
    }

    private func row(_ item: CatchUp.Pending) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.ui(14)).foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Self.dayName(item.day)) · \(item.plannedMinutes) min · \(item.reason.label)")
                    .font(.ui(11)).foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                choice("Didn't", isOn: answers[item.blockKey] == false) {
                    answers[item.blockKey] = false
                }
                choice("Did it", isOn: answers[item.blockKey] == true) {
                    answers[item.blockKey] = true
                }
            }
        }
        .padding(.vertical, 11)
    }

    private func choice(_ label: String, isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.ui(12.5, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .white : Color.textPrimary)
                .padding(.horizontal, 12).frame(minHeight: 34)
                .background(Capsule().fill(isOn ? Color.accent : Color.surface))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        for item in pending {
            guard let didIt = answers[item.blockKey] else { continue }
            if didIt {
                // No count — they're recalling a day later, and a guessed
                // number is worse than an honest "logged, no count given",
                // which the adherence screen reports as its own kind of gap.
                ActivityTracker.logRetroactively(
                    blockKey: item.blockKey, title: item.title,
                    plannedMinutes: item.plannedMinutes, day: item.day,
                    quantity: nil, context: context)
            } else {
                let state = DailyPlanState.forDay(item.day, in: context)
                state.setManualOutcome(.skipped, forKey: item.blockKey)
                // A session that closed itself but didn't happen was never
                // work — drop the claim rather than leaving a phantom.
                if let session = ActivitySession.forBlock(key: item.blockKey, day: item.day, in: context),
                   session.state == .needsDetail {
                    session.cancel()
                }
            }
        }
        context.saveOrLog("catchUp.save")
        CatchUp.markAsked()
        onFinished()
        dismiss()
    }

    private static func dayName(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: day)
    }
}
