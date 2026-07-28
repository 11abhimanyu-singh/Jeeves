//
//  LiftView.swift
//  Jeeves
//
//  The weightlifting logger. Pick an exercise from a searchable, muscle-grouped
//  library, then stack sets: each with a Weighted / Bodyweight / Isometric input
//  type that swaps the fields it shows (weight, added-load, or a hold timer). A
//  live tonnage total updates as you edit. "Save session" persists a LiftSession
//  plus its LiftSets (linked by sessionID). Recent sessions show at the bottom of
//  the picker. Warm-editorial styling, standalone in its own NavigationStack.
//

import SwiftUI
import SwiftData
import Foundation

struct LiftView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \LiftSession.date, order: .reverse) private var sessions: [LiftSession]
    @Query private var allLiftSets: [LiftSet]

    // Draft state — the in-progress session, edited as plain values so the live
    // tonnage recomputes without touching the store until "Save".
    @State private var selectedExercise: LiftExercise?
    @State private var searchText = ""
    @State private var draftSets: [DraftSet] = []
    @State private var justSaved = false

    /// One editable set before it's persisted. Value type so @State drives the
    /// live total; mirrors LiftSet's fields.
    private struct DraftSet: Identifiable {
        let id = UUID()
        var inputType: LiftInputType = .weighted
        var reps: Int = 5
        var weightKg: Double = 20
        var addedKg: Double = 0
        var bodyweightKg: Double = 75
        var holdSeconds: Int = 30

        var tonnage: Double {
            LiftMath.setTonnage(inputType: inputType, reps: reps, weightKg: weightKg,
                                bodyweightKg: bodyweightKg, addedKg: addedKg)
        }
    }

    /// A muscle group and its (possibly search-filtered) exercises, wrapped so
    /// ForEach has a clean Identifiable to key on.
    private struct LiftGroupSection: Identifiable {
        let id: LiftGroup
        let exercises: [LiftExercise]
        var group: LiftGroup { id }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if selectedExercise == nil {
                    pickerScreen
                } else {
                    loggerScreen
                }
            }
            .background(Color.bg)
            .navigationTitle("Lift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(Color.accentDeep)
                }
            }
        }
    }

    // MARK: - Picker screen

    private var pickerScreen: some View {
        List {
            if justSaved && searchQuery.isEmpty {
                Section {
                    savedChip.listRowBackground(Color.sageLight)
                }
            }

            ForEach(groupedResults) { section in
                Section {
                    ForEach(section.exercises) { ex in
                        Button { select(ex) } label: { exerciseRow(ex) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.surface)
                    }
                } header: {
                    sectionHeader(section.group.rawValue)
                }
            }

            if groupedResults.isEmpty {
                Section {
                    Text("No exercises match \u{201C}\(searchQuery)\u{201D}")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textMuted)
                        .listRowBackground(Color.surface)
                }
            }

            if searchQuery.isEmpty && !sessions.isEmpty {
                Section {
                    ForEach(recentSessions, id: \.id) { s in
                        recentRow(s).listRowBackground(Color.surface)
                    }
                } header: {
                    sectionHeader("Recent sessions")
                }
            }
        }
        .listStyle(.insetGrouped)
        .jeevesFormChrome()
        .searchable(text: $searchText, prompt: "Search exercises")
    }

    private var savedChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.sageDeep)
            Text("Session saved")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.sageDeep)
        }
    }

    private func exerciseRow(_ ex: LiftExercise) -> some View {
        HStack {
            Text(ex.name)
                .font(.system(size: 15.5, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.textMuted)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func recentRow(_ s: LiftSession) -> some View {
        let sets = setsFor(s)
        return VStack(alignment: .leading, spacing: 3) {
            Text(s.exerciseName.isEmpty ? "Lift" : s.exerciseName)
                .font(.serif(16))
                .foregroundStyle(Color.textPrimary)
            Text(sessionSummary(s, sets: sets))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.textSoft)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Logger screen

    @ViewBuilder
    private var loggerScreen: some View {
        if let ex = selectedExercise {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    exerciseHeader(ex)
                    tonnageCard
                    ForEach($draftSets) { $set in
                        setCard($set)
                    }
                    addSetButton
                    saveButton
                }
                .padding(20)
            }
            .background(Color.bg)
        }
    }

    private func exerciseHeader(_ ex: LiftExercise) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ex.group.rawValue.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.accentDeep)
                Text(ex.name)
                    .font(.serif(26))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                selectedExercise = nil
                draftSets = []
            } label: {
                Text("Change")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentDeep)
            }
            .buttonStyle(.plain)
        }
    }

    private var tonnageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LIVE TONNAGE")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.accentDeep)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tonnageText(totalTonnage))
                    .font(.serif(40))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                Text("kg")
                    .font(.serif(18))
                    .foregroundStyle(Color.textSoft)
            }
            Text(tonnageSubtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.textMuted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private func setCard(_ set: Binding<DraftSet>) -> some View {
        let d = set.wrappedValue
        let idx = (draftSets.firstIndex { $0.id == d.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SET \(idx)")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.accentDeep)
                Spacer()
                Button {
                    draftSets.removeAll { $0.id == d.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textMuted)
                }
                .buttonStyle(.plain)
            }

            Picker("", selection: set.inputType) {
                ForEach(LiftInputType.allCases, id: \.self) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)

            switch d.inputType {
            case .weighted:
                stepControl("Reps", value: "\(d.reps)",
                            dec: { set.wrappedValue.reps = max(0, set.wrappedValue.reps - 1) },
                            inc: { set.wrappedValue.reps += 1 })
                stepControl("Weight", value: "\(kg(d.weightKg)) kg",
                            dec: { set.wrappedValue.weightKg = max(0, set.wrappedValue.weightKg - 2.5) },
                            inc: { set.wrappedValue.weightKg += 2.5 })
            case .bodyweight:
                stepControl("Reps", value: "\(d.reps)",
                            dec: { set.wrappedValue.reps = max(0, set.wrappedValue.reps - 1) },
                            inc: { set.wrappedValue.reps += 1 })
                stepControl("Bodyweight", value: "\(kg(d.bodyweightKg)) kg",
                            dec: { set.wrappedValue.bodyweightKg = max(0, set.wrappedValue.bodyweightKg - 0.5) },
                            inc: { set.wrappedValue.bodyweightKg += 0.5 })
                stepControl("Added load", value: "\(kg(d.addedKg)) kg",
                            dec: { set.wrappedValue.addedKg = max(0, set.wrappedValue.addedKg - 2.5) },
                            inc: { set.wrappedValue.addedKg += 2.5 })
            case .isometric:
                stepControl("Hold", value: "\(d.holdSeconds)s",
                            dec: { set.wrappedValue.holdSeconds = max(0, set.wrappedValue.holdSeconds - 5) },
                            inc: { set.wrappedValue.holdSeconds += 5 })
            }

            Divider().overlay(Color.textPrimary.opacity(0.08))
            Text(setSummary(d))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.textSoft)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private func stepControl(_ title: String, value: String,
                             dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.textSoft)
            Spacer()
            HStack(spacing: 12) {
                stepButton("minus", action: dec)
                Text(value)
                    .font(.serif(18))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .frame(minWidth: 74)
                    .multilineTextAlignment(.center)
                stepButton("plus", action: inc)
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.bg))
        }
        .buttonStyle(.plain)
    }

    private var addSetButton: some View {
        Button { addSet() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("Add set")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.accentDeep)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        Button { saveSession() } label: {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                Text("Save session")
                    .font(.serif(17))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Capsule().fill(draftSets.isEmpty ? Color.textMuted.opacity(0.5) : Color.accent))
        }
        .buttonStyle(.plain)
        .disabled(draftSets.isEmpty)
        .padding(.top, 2)
    }

    // MARK: - Derived state

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var groupedResults: [LiftGroupSection] {
        let q = searchQuery.lowercased()
        return LiftGroup.allCases.compactMap { group in
            let items = LiftExercise.library.filter { ex in
                ex.group == group && (q.isEmpty || ex.name.lowercased().contains(q))
            }
            return items.isEmpty ? nil : LiftGroupSection(id: group, exercises: items)
        }
    }

    private var recentSessions: [LiftSession] {
        Array(sessions.prefix(8))
    }

    private var totalTonnage: Double {
        draftSets.reduce(0) { $0 + $1.tonnage }
    }

    private var totalHold: Int {
        draftSets.reduce(0) { $0 + ($1.inputType == .isometric ? $1.holdSeconds : 0) }
    }

    private var tonnageSubtitle: String {
        let n = draftSets.count
        var parts = ["\(n) set\(n == 1 ? "" : "s")"]
        if totalHold > 0 { parts.append("\(totalHold)s isometric hold") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func setsFor(_ session: LiftSession) -> [LiftSet] {
        allLiftSets.filter { $0.sessionID == session.id }
    }

    private func sessionSummary(_ s: LiftSession, sets: [LiftSet]) -> String {
        let n = sets.count
        let setLabel = "\(n) set\(n == 1 ? "" : "s")"
        let day = dayLabel(s.date)
        let ton = LiftMath.sessionTonnage(sets)
        if ton > 0 {
            return "\(day) \u{00B7} \(tonnageText(ton)) kg \u{00B7} \(setLabel)"
        }
        let hold = LiftMath.totalHoldSeconds(sets)
        if hold > 0 {
            return "\(day) \u{00B7} \(hold)s hold \u{00B7} \(setLabel)"
        }
        return "\(day) \u{00B7} \(setLabel)"
    }

    private func setSummary(_ d: DraftSet) -> String {
        switch d.inputType {
        case .weighted, .bodyweight:
            return "\(d.reps) reps \u{00B7} \(tonnageText(d.tonnage)) kg tonnage"
        case .isometric:
            return "\(d.holdSeconds)s hold \u{00B7} no tonnage"
        }
    }

    // MARK: - Actions

    private func select(_ ex: LiftExercise) {
        selectedExercise = ex
        justSaved = false
        if draftSets.isEmpty {
            draftSets = [DraftSet()]
        }
    }

    private func addSet() {
        // Carry the previous set's shape forward so stacking sets is quick.
        if let base = draftSets.last {
            draftSets.append(DraftSet(inputType: base.inputType, reps: base.reps,
                                      weightKg: base.weightKg, addedKg: base.addedKg,
                                      bodyweightKg: base.bodyweightKg, holdSeconds: base.holdSeconds))
        } else {
            draftSets.append(DraftSet())
        }
    }

    private func saveSession() {
        guard let ex = selectedExercise, !draftSets.isEmpty else { return }
        let session = LiftSession(date: Date(), exerciseName: ex.name)
        modelContext.insert(session)
        for (i, d) in draftSets.enumerated() {
            let s = LiftSet(sessionID: session.id, order: i, reps: d.reps, weightKg: d.weightKg,
                            inputType: d.inputType, holdSeconds: d.holdSeconds,
                            addedKg: d.addedKg, bodyweightKg: d.bodyweightKg)
            modelContext.insert(s)
        }
        try? modelContext.save()

        // Back to the picker; the new session appears under "Recent sessions".
        draftSets = []
        selectedExercise = nil
        searchText = ""
        justSaved = true
    }

    // MARK: - Formatting

    /// A kg value with at most one decimal, no trailing ".0".
    private func kg(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    /// Whole-kg tonnage with thousands grouping ("1,240").
    private func tonnageText(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v.rounded())) ?? "0"
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 12.5, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Color.accentDeep)
    }
}
