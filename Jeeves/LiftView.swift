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

    // Live heart rate while lifting: the Watch runs the workout and streams BPM;
    // HealthKit is the fallback source. sessionStart marks when the logger opened
    // so we can average HR over the session on save.
    @StateObject private var hr = HeartRateMonitor()
    @ObservedObject private var watchLink = WatchLink.shared
    @State private var sessionStart: Date?

    private var liveBPM: Int? { watchLink.currentBPM ?? hr.currentBPM }

    // Tap-to-type numeric entry (reps / weight / hold), shared by every field.
    @State private var showEdit = false
    @State private var editTitle = ""
    @State private var editText = ""
    @State private var editIsInt = false
    @State private var editApply: ((Double) -> Void)?

    private func promptEdit(_ title: String, current: Double, isInt: Bool,
                            apply: @escaping (Double) -> Void) {
        editTitle = title
        editIsInt = isInt
        editText = isInt ? String(Int(current))
                         : (current == current.rounded() ? String(Int(current)) : String(current))
        editApply = apply
        showEdit = true
    }

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
            .onDisappear {
                // Stop streaming + end the Watch workout when the logger closes.
                hr.stop()
                watchLink.stopWorkout()
            }
            .alert(editTitle, isPresented: $showEdit) {
                TextField("Value", text: $editText)
                    .keyboardType(editIsInt ? .numberPad : .decimalPad)
                Button("Set") {
                    if let v = Double(editText.replacingOccurrences(of: ",", with: ".")) {
                        editApply?(max(0, v))
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(editIsInt ? "Type a whole number." : "Type the value in kg.")
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
                        .font(.ui(14))
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
                .font(.ui(14, weight: .semibold))
                .foregroundStyle(Color.sageDeep)
        }
    }

    private func exerciseRow(_ ex: LiftExercise) -> some View {
        HStack {
            Text(ex.name)
                .font(.ui(15.5, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.ui(12, weight: .semibold))
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
                .font(.ui(12.5))
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
                    heartRatePill
                    tonnageCard
                    ForEach($draftSets) { $set in
                        setCard($set)
                    }
                }
                .padding(20)
            }
            .background(Color.bg)
            // Keep Add set + Save pinned so they're always reachable no matter
            // how many sets are logged.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    addSetButton
                    saveButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(Color.bg)
                .overlay(alignment: .top) {
                    Divider().overlay(Color.textPrimary.opacity(0.08))
                }
            }
        }
    }

    private func exerciseHeader(_ ex: LiftExercise) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ex.group.rawValue.uppercased())
                    .font(.ui(12, weight: .semibold))
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
                    .font(.ui(14, weight: .semibold))
                    .foregroundStyle(Color.accentDeep)
            }
            .buttonStyle(.plain)
        }
    }

    private var tonnageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LIVE TONNAGE")
                .font(.ui(12, weight: .semibold))
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
                .font(.ui(12.5))
                .foregroundStyle(Color.textMuted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    /// Live heart rate streamed from the Apple Watch during the session.
    private var heartRatePill: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.ui(14))
                .foregroundStyle(Color(red: 0.70, green: 0.23, blue: 0.18))
            if let bpm = liveBPM {
                Text("\(bpm)")
                    .font(.serif(20))
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
                Text("BPM")
                    .font(.ui(12, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
            } else {
                Text("Waiting for Apple Watch\u{2026}")
                    .font(.ui(13))
                    .foregroundStyle(Color.textMuted)
            }
            Spacer()
            Text("Strength \u{00B7} live HR")
                .font(.ui(11))
                .foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
    }

    private func setCard(_ set: Binding<DraftSet>) -> some View {
        let d = set.wrappedValue
        let idx = (draftSets.firstIndex { $0.id == d.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SET \(idx)")
                    .font(.ui(12, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.accentDeep)
                Spacer()
                Button {
                    draftSets.removeAll { $0.id == d.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.ui(14))
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
                            inc: { set.wrappedValue.reps += 1 },
                            edit: { promptEdit("Reps", current: Double(d.reps), isInt: true) { set.wrappedValue.reps = Int($0) } })
                stepControl("Weight", value: "\(kg(d.weightKg)) kg",
                            dec: { set.wrappedValue.weightKg = max(0, set.wrappedValue.weightKg - 2.5) },
                            inc: { set.wrappedValue.weightKg += 2.5 },
                            edit: { promptEdit("Weight (kg)", current: d.weightKg, isInt: false) { set.wrappedValue.weightKg = $0 } })
            case .bodyweight:
                stepControl("Reps", value: "\(d.reps)",
                            dec: { set.wrappedValue.reps = max(0, set.wrappedValue.reps - 1) },
                            inc: { set.wrappedValue.reps += 1 },
                            edit: { promptEdit("Reps", current: Double(d.reps), isInt: true) { set.wrappedValue.reps = Int($0) } })
                stepControl("Bodyweight", value: "\(kg(d.bodyweightKg)) kg",
                            dec: { set.wrappedValue.bodyweightKg = max(0, set.wrappedValue.bodyweightKg - 0.5) },
                            inc: { set.wrappedValue.bodyweightKg += 0.5 },
                            edit: { promptEdit("Bodyweight (kg)", current: d.bodyweightKg, isInt: false) { set.wrappedValue.bodyweightKg = $0 } })
                stepControl("Added load", value: "\(kg(d.addedKg)) kg",
                            dec: { set.wrappedValue.addedKg = max(0, set.wrappedValue.addedKg - 2.5) },
                            inc: { set.wrappedValue.addedKg += 2.5 },
                            edit: { promptEdit("Added load (kg)", current: d.addedKg, isInt: false) { set.wrappedValue.addedKg = $0 } })
            case .isometric:
                stepControl("Hold", value: "\(d.holdSeconds)s",
                            dec: { set.wrappedValue.holdSeconds = max(0, set.wrappedValue.holdSeconds - 5) },
                            inc: { set.wrappedValue.holdSeconds += 5 },
                            edit: { promptEdit("Hold (seconds)", current: Double(d.holdSeconds), isInt: true) { set.wrappedValue.holdSeconds = Int($0) } })
            }

            Divider().overlay(Color.textPrimary.opacity(0.08))
            Text(setSummary(d))
                .font(.ui(12.5, weight: .medium))
                .foregroundStyle(Color.textSoft)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private func stepControl(_ title: String, value: String,
                             dec: @escaping () -> Void, inc: @escaping () -> Void,
                             edit: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.ui(14, weight: .medium))
                .foregroundStyle(Color.textSoft)
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                stepButton("minus", action: dec)
                // Tap the value to type it (fast for big jumps, e.g. 20 → 150 kg).
                // Single line + scaling so 5-digit weights like 100.5 kg don't wrap.
                Button { edit?() } label: {
                    Text(value)
                        .font(.serif(18))
                        .foregroundStyle(Color.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(minWidth: 92)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                .disabled(edit == nil)
                stepButton("plus", action: inc)
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(13, weight: .bold))
                .foregroundStyle(Color.accentDeep)
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
                    .font(.ui(15, weight: .semibold))
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
            .background(Capsule().fill(draftSets.isEmpty ? Color.textMuted : Color.accent))
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
        let hold = LiftMath.totalHoldSeconds(sets)
        var base: String
        if ton > 0 {
            base = "\(day) \u{00B7} \(tonnageText(ton)) kg \u{00B7} \(setLabel)"
        } else if hold > 0 {
            base = "\(day) \u{00B7} \(hold)s hold \u{00B7} \(setLabel)"
        } else {
            base = "\(day) \u{00B7} \(setLabel)"
        }
        if s.avgBPM > 0 {
            base += " \u{00B7} \u{2665} \(s.avgBPM)"
        }
        return base
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
        // Begin the session's heart-rate capture the first time the logger opens:
        // ask the Watch to run a strength workout (the HR source) and start the
        // phone's HealthKit reader. Safe if a session is already running.
        if sessionStart == nil {
            sessionStart = Date()
            watchLink.startWorkout(activity: "strength")
            Task { await hr.requestAuthorization(); hr.start() }
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
        let start = sessionStart ?? Date()
        let drafts = draftSets
        let name = ex.name
        // Average the session's heart rate, then persist. The Task inherits the
        // main actor (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), so the store
        // work stays on the main actor.
        Task {
            let avg = await hr.averageBPM(from: start, to: Date()) ?? 0
            let session = LiftSession(date: start, exerciseName: name, avgBPM: avg)
            modelContext.insert(session)
            for (i, d) in drafts.enumerated() {
                let s = LiftSet(sessionID: session.id, order: i, reps: d.reps, weightKg: d.weightKg,
                                inputType: d.inputType, holdSeconds: d.holdSeconds,
                                addedKg: d.addedKg, bodyweightKg: d.bodyweightKg)
                modelContext.insert(s)
            }
            modelContext.saveOrLog()
            hr.stop()
            watchLink.stopWorkout()

            // Back to the picker; the new session appears under "Recent sessions".
            draftSets = []
            selectedExercise = nil
            searchText = ""
            justSaved = true
            sessionStart = nil
        }
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
            .font(.ui(12.5, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Color.accentDeep)
    }
}
