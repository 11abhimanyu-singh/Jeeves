//
//  WorkoutViews.swift
//  Jeeves
//
//  The unified workout experience on the phone:
//    • WorkoutTodaySection — the Fitness tab's Today feed: every workout of the
//      day as a card (live / needs-detail / logged), a "+ Workout" entry for
//      watchless days, and the door to History.
//    • WorkoutLiftView — ONE screen for a whole lifting session: stack every
//      exercise with its sets, live watch HR while it runs, a single
//      Save & Close at the end.
//    • WalkDetailView — enrich a walk with minutes + treadmill incline.
//    • WorkoutHistoryView — past days, tap any workout for the full log.
//
//  Runs stay in RunView (unchanged); its card here just opens it.
//

import SwiftUI
import SwiftData

// MARK: - Today section

struct WorkoutTodaySection: View {
    /// Today's run card / "+ Workout → run" open the existing run tool, which
    /// the parent presents.
    var onRun: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workout.date, order: .reverse) private var workouts: [Workout]
    @Query private var liftSessions: [LiftSession]
    @Query private var liftSets: [LiftSet]

    @State private var editing: Workout?
    @State private var showHistory = false
    @State private var showNew = false

    private var today: [Workout] {
        workouts.filter { Calendar.current.isDateInToday($0.date) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Today")
                    .font(.system(size: 11, weight: .bold)).textCase(.uppercase)
                    .kerning(0.9).foregroundStyle(Color.accentDeep)
                Spacer()
                Button { showHistory = true } label: {
                    HStack(spacing: 4) {
                        Text("History").font(.system(size: 12.5, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Color.accentDeep)
                }
                .buttonStyle(.plain)
            }

            if today.isEmpty {
                Text("Nothing yet today.\nStart a workout on your watch \u{2014} it lands here.")
                    .font(.system(size: 13)).foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
            }

            ForEach(today, id: \.id) { w in
                WorkoutCard(workout: w, summary: liftSummary(w)) { open(w) }
            }

            Button { showNew = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Workout").font(.system(size: 14.5, weight: .semibold))
                }
                .foregroundStyle(Color.accentDeep)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentDeep.opacity(0.45), style: StrokeStyle(lineWidth: 1.4, dash: [5])))
            }
            .buttonStyle(.plain)
        }
        .sheet(item: $editing) { w in
            if w.type == .walk {
                WalkDetailView(workout: w)
            } else {
                WorkoutLiftView(workout: w)
            }
        }
        .sheet(isPresented: $showHistory) { WorkoutHistoryView() }
        .confirmationDialog("Start without the watch", isPresented: $showNew, titleVisibility: .visible) {
            Button("Go for the run") { onRun() }
            Button("Weightlifting") { editing = newManual(.lift, title: "Lift") }
            Button("Walk") { editing = newManual(.walk, title: "Walk") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs use the full run tool. Lifts and walks are logged manually \u{2014} no heart rate or auto-duration.")
        }
    }

    private func open(_ w: Workout) {
        switch w.type {
        case .run:  onRun()
        default:    editing = w
        }
    }

    private func newManual(_ type: WorkoutType, title: String) -> Workout {
        let w = Workout(date: Date(), type: type, state: .needsDetail,
                        source: .manual, title: title)
        modelContext.insert(w)
        return w
    }

    /// "Bench Press (3×) · Front Squat (2×)" for a lift card, nil otherwise.
    private func liftSummary(_ w: Workout) -> String? {
        guard w.type == .lift else { return nil }
        let sessions = liftSessions.filter { $0.workoutID == w.id }
        guard !sessions.isEmpty else { return nil }
        return sessions
            .map { s in "\(s.exerciseName) (\(liftSets.filter { $0.sessionID == s.id }.count)\u{00D7})" }
            .joined(separator: " \u{00B7} ")
    }
}

// MARK: - Card

struct WorkoutCard: View {
    let workout: Workout
    var summary: String?          // lift exercise list line
    var onTap: (() -> Void)?

    private var icon: String {
        switch workout.type {
        case .lift: return "dumbbell.fill"
        case .run:  return "figure.run"
        case .walk: return "figure.walk"
        }
    }
    private var stripe: Color {
        switch workout.type {
        case .lift: return Color.sage
        case .run:  return Color.accent
        case .walk: return Color(red: 0.78, green: 0.60, blue: 0.24)
        }
    }

    var body: some View {
        Button { onTap?() } label: {
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(stripe).frame(width: 4)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: icon).font(.system(size: 15))
                            .foregroundStyle(stripe)
                        Text(workout.title.isEmpty ? "Workout" : workout.title)
                            .font(Font.serif(16, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        Spacer(minLength: 6)
                        chip
                    }
                    metaLine
                    if let summary {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(2)
                    }
                    Text(sourceLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.textMuted.opacity(0.8))
                }
                .padding(.leading, 12)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 15).fill(Color.surface))
        }
        .buttonStyle(.plain)
    }

    private var chip: some View {
        Group {
            switch workout.state {
            case .live:
                chipText("In progress", fg: Color(red: 0.63, green: 0.23, blue: 0.16),
                         bg: Color(red: 0.96, green: 0.87, blue: 0.83))
            case .needsDetail:
                chipText(workout.type == .lift ? "Add sets" : "Add details",
                         fg: Color.accentDeep, bg: Color.accentDeep.opacity(0.12))
            case .done:
                chipText("Logged", fg: Color.sageDeep, bg: Color.sageLight)
            }
        }
    }

    private func chipText(_ t: String, fg: Color, bg: Color) -> some View {
        Text(t)
            .font(.system(size: 10, weight: .bold)).textCase(.uppercase).kerning(0.5)
            .foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(bg))
    }

    private var metaLine: some View {
        HStack(spacing: 12) {
            if workout.durationMin > 0 {
                Text("\(workout.durationMin) min")
            }
            if workout.avgBPM > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.70, green: 0.23, blue: 0.18))
                    Text("\(workout.avgBPM)")
                }
            }
            if workout.distanceKm > 0 {
                Text(String(format: "%.1f km", workout.distanceKm))
            }
            if workout.type == .walk, workout.state == .done {
                Text("incline \(trimmed(workout.inclinePercent))%")
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(Color.textSoft)
        .monospacedDigit()
    }

    private var sourceLabel: String {
        switch workout.source {
        case .watch:  return "\u{231A} from watch"
        case .phone:  return "\u{1F4F1} on phone"
        case .manual: return "\u{270D}\u{FE0E} manual"
        }
    }

    private func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}

// MARK: - Lift workout: one screen, many exercises, one save

struct WorkoutLiftView: View {
    let workout: Workout
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var watchLink = WatchLink.shared

    @State private var exercises: [DraftExercise] = []
    @State private var showPicker = false
    @State private var pickerSearch = ""
    @State private var saved = false

    // Tap-to-type numeric entry, shared by every field.
    @State private var showEdit = false
    @State private var editTitle = ""
    @State private var editText = ""
    @State private var editIsInt = false
    @State private var editApply: ((Double) -> Void)?

    struct DraftSet: Identifiable {
        let id = UUID()
        var inputType: LiftInputType = .weighted
        var reps: Int = 8
        var weightKg: Double = 40
        var addedKg: Double = 0
        var bodyweightKg: Double = 75
        var holdSeconds: Int = 30

        var tonnage: Double {
            LiftMath.setTonnage(inputType: inputType, reps: reps, weightKg: weightKg,
                                bodyweightKg: bodyweightKg, addedKg: addedKg)
        }
    }
    struct DraftExercise: Identifiable {
        let id = UUID()
        var name: String
        var sets: [DraftSet]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsRow
                    if workout.state == .live || watchLink.currentBPM != nil {
                        liveHRPill
                    }
                    ForEach($exercises) { $ex in
                        exerciseBlock($ex)
                    }
                    addExerciseButton
                }
                .padding(18)
            }
            .background(Color.bg)
            .navigationTitle(workout.title.isEmpty ? "Lift" : workout.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.tint(Color.accentDeep)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { save() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill")
                        Text("Save & Close").font(Font.serif(17))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(exercises.isEmpty ? Color.textMuted.opacity(0.5) : Color.accent))
                }
                .buttonStyle(.plain)
                .disabled(exercises.isEmpty)
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 6)
                .background(Color.bg)
            }
            .sheet(isPresented: $showPicker) { exercisePicker }
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
            .onAppear(perform: load)
            .onDisappear(perform: cleanupIfAbandoned)
        }
    }

    // MARK: header

    private var statsRow: some View {
        HStack(spacing: 10) {
            stat("Duration", workout.durationMin > 0 ? "\(workout.durationMin) min" : "\u{2014}")
            stat("Avg HR", workout.avgBPM > 0 ? "\u{2665} \(workout.avgBPM)" : "\u{2014}")
            stat("Tonnage", "\(Int(totalTonnage.rounded())) kg")
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k.uppercased())
                .font(.system(size: 10, weight: .bold)).kerning(0.8)
                .foregroundStyle(Color.textMuted)
            Text(v)
                .font(Font.serif(17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.surface))
    }

    private var liveHRPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.70, green: 0.23, blue: 0.18))
            if let bpm = watchLink.currentBPM {
                Text("\(bpm)").font(Font.serif(18)).monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
                Text("BPM").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
            } else {
                Text("Watch workout in progress\u{2026}")
                    .font(.system(size: 12.5)).foregroundStyle(Color.textMuted)
            }
            Spacer()
            Text("live from watch").font(.system(size: 10.5)).foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
    }

    // MARK: exercise blocks

    private func exerciseBlock(_ ex: Binding<DraftExercise>) -> some View {
        let e = ex.wrappedValue
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(e.name)
                    .font(Font.serif(18, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Button {
                    exercises.removeAll { $0.id == e.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13)).foregroundStyle(Color.textMuted)
                }
                .buttonStyle(.plain)
            }

            ForEach(ex.sets) { $set in
                setRow(exercise: ex, set: $set)
            }

            Button {
                let base = e.sets.last ?? DraftSet()
                ex.wrappedValue.sets.append(DraftSet(inputType: base.inputType, reps: base.reps,
                                                     weightKg: base.weightKg, addedKg: base.addedKg,
                                                     bodyweightKg: base.bodyweightKg,
                                                     holdSeconds: base.holdSeconds))
            } label: {
                Text("\u{FF0B} Add set\(e.sets.isEmpty ? "" : " (same as last)")")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.accentDeep)
            }
            .buttonStyle(.plain)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.surface))
    }

    private func setRow(exercise: Binding<DraftExercise>, set: Binding<DraftSet>) -> some View {
        let d = set.wrappedValue
        let idx = (exercise.wrappedValue.sets.firstIndex { $0.id == d.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SET \(idx)")
                    .font(.system(size: 10.5, weight: .bold)).kerning(0.8)
                    .foregroundStyle(Color.accentDeep)
                Spacer()
                Text(d.inputType == .isometric
                     ? "\(d.holdSeconds)s hold"
                     : "\(Int(d.tonnage.rounded())) kg")
                    .font(.system(size: 11)).foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                Button { exercise.wrappedValue.sets.removeAll { $0.id == d.id } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.textMuted)
                }
                .buttonStyle(.plain)
            }
            Picker("", selection: set.inputType) {
                ForEach(LiftInputType.allCases, id: \.self) { t in Text(t.label).tag(t) }
            }
            .pickerStyle(.segmented)

            switch d.inputType {
            case .weighted:
                valueRow("Reps", "\(d.reps)",
                         dec: { set.wrappedValue.reps = max(0, d.reps - 1) },
                         inc: { set.wrappedValue.reps = d.reps + 1 },
                         edit: { promptEdit("Reps", current: Double(d.reps), isInt: true) { set.wrappedValue.reps = Int($0) } })
                valueRow("Weight", "\(kg(d.weightKg)) kg",
                         dec: { set.wrappedValue.weightKg = max(0, d.weightKg - 2.5) },
                         inc: { set.wrappedValue.weightKg = d.weightKg + 2.5 },
                         edit: { promptEdit("Weight (kg)", current: d.weightKg, isInt: false) { set.wrappedValue.weightKg = $0 } })
            case .bodyweight:
                valueRow("Reps", "\(d.reps)",
                         dec: { set.wrappedValue.reps = max(0, d.reps - 1) },
                         inc: { set.wrappedValue.reps = d.reps + 1 },
                         edit: { promptEdit("Reps", current: Double(d.reps), isInt: true) { set.wrappedValue.reps = Int($0) } })
                valueRow("Bodyweight", "\(kg(d.bodyweightKg)) kg",
                         dec: { set.wrappedValue.bodyweightKg = max(0, d.bodyweightKg - 0.5) },
                         inc: { set.wrappedValue.bodyweightKg = d.bodyweightKg + 0.5 },
                         edit: { promptEdit("Bodyweight (kg)", current: d.bodyweightKg, isInt: false) { set.wrappedValue.bodyweightKg = $0 } })
                valueRow("Added load", "\(kg(d.addedKg)) kg",
                         dec: { set.wrappedValue.addedKg = max(0, d.addedKg - 2.5) },
                         inc: { set.wrappedValue.addedKg = d.addedKg + 2.5 },
                         edit: { promptEdit("Added load (kg)", current: d.addedKg, isInt: false) { set.wrappedValue.addedKg = $0 } })
            case .isometric:
                valueRow("Hold", "\(d.holdSeconds)s",
                         dec: { set.wrappedValue.holdSeconds = max(0, d.holdSeconds - 5) },
                         inc: { set.wrappedValue.holdSeconds = d.holdSeconds + 5 },
                         edit: { promptEdit("Hold (seconds)", current: Double(d.holdSeconds), isInt: true) { set.wrappedValue.holdSeconds = Int($0) } })
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.bg))
    }

    private func valueRow(_ title: String, _ value: String,
                          dec: @escaping () -> Void, inc: @escaping () -> Void,
                          edit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.textSoft)
            Spacer(minLength: 4)
            HStack(spacing: 9) {
                roundButton("minus", action: dec)
                Button(action: edit) {
                    Text(value)
                        .font(Font.serif(17))
                        .foregroundStyle(Color.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(minWidth: 84)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                roundButton("plus", action: inc)
            }
        }
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.surface))
        }
        .buttonStyle(.plain)
    }

    private var addExerciseButton: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("Add exercise").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.accentDeep)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentDeep.opacity(0.45), style: StrokeStyle(lineWidth: 1.4, dash: [5])))
        }
        .buttonStyle(.plain)
    }

    private var exercisePicker: some View {
        NavigationStack {
            List {
                ForEach(pickerGroups, id: \.id) { section in
                    Section {
                        ForEach(section.exercises) { ex in
                            Button {
                                // One block per exercise: picking one that's
                                // already in the workout adds a set to it
                                // (prefilled from its last set) instead of
                                // creating a duplicate block.
                                if let i = exercises.firstIndex(where: { $0.name == ex.name }) {
                                    let base = exercises[i].sets.last ?? DraftSet()
                                    exercises[i].sets.append(DraftSet(
                                        inputType: base.inputType, reps: base.reps,
                                        weightKg: base.weightKg, addedKg: base.addedKg,
                                        bodyweightKg: base.bodyweightKg,
                                        holdSeconds: base.holdSeconds))
                                } else {
                                    exercises.append(DraftExercise(name: ex.name, sets: [DraftSet()]))
                                }
                                showPicker = false
                                pickerSearch = ""
                            } label: {
                                HStack {
                                    Text(ex.name)
                                        .font(.system(size: 15.5, weight: .medium))
                                        .foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.accentDeep)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.surface)
                        }
                    } header: {
                        Text(section.group.rawValue)
                            .font(.system(size: 12.5, weight: .semibold)).kerning(1.1)
                            .foregroundStyle(Color.accentDeep)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .jeevesFormChrome()
            .searchable(text: $pickerSearch, prompt: "Search exercises")
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showPicker = false }.tint(Color.accentDeep)
                }
            }
        }
    }

    private struct PickerSection: Identifiable {
        let id: LiftGroup
        let exercises: [LiftExercise]
        var group: LiftGroup { id }
    }

    private var pickerGroups: [PickerSection] {
        let q = pickerSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return LiftGroup.allCases.compactMap { group in
            let items = LiftExercise.library.filter { ex in
                ex.group == group && (q.isEmpty || ex.name.lowercased().contains(q))
            }
            return items.isEmpty ? nil : PickerSection(id: group, exercises: items)
        }
    }

    // MARK: data

    private var totalTonnage: Double {
        exercises.reduce(0) { $0 + $1.sets.reduce(0) { $0 + $1.tonnage } }
    }

    private func promptEdit(_ title: String, current: Double, isInt: Bool,
                            apply: @escaping (Double) -> Void) {
        editTitle = title
        editIsInt = isInt
        editText = isInt ? String(Int(current))
                         : (current == current.rounded() ? String(Int(current)) : String(current))
        editApply = apply
        showEdit = true
    }

    /// Load any already-persisted exercises (reopening a saved workout).
    private func load() {
        guard exercises.isEmpty else { return }
        let wid = workout.id
        let sessions = ((try? modelContext.fetch(FetchDescriptor<LiftSession>())) ?? [])
            .filter { $0.workoutID == wid }
            .sorted { $0.date < $1.date }
        guard !sessions.isEmpty else { return }
        let allSets = ((try? modelContext.fetch(FetchDescriptor<LiftSet>())) ?? [])
        let drafts = sessions.map { s in
            let sets = allSets.filter { $0.sessionID == s.id }.sorted { $0.order < $1.order }
                .map { ls in
                    DraftSet(inputType: ls.inputType, reps: ls.reps, weightKg: ls.weightKg,
                             addedKg: ls.addedKg, bodyweightKg: ls.bodyweightKg,
                             holdSeconds: ls.holdSeconds)
                }
            return DraftExercise(name: s.exerciseName, sets: sets)
        }
        // Merge same-named blocks (older workouts could hold duplicates): all
        // of an exercise's sets live under one entry, in logged order.
        var merged: [DraftExercise] = []
        for e in drafts {
            if let i = merged.firstIndex(where: { $0.name == e.name }) {
                merged[i].sets.append(contentsOf: e.sets)
            } else {
                merged.append(e)
            }
        }
        exercises = merged
    }

    /// One save covers the whole session: replace the workout's persisted
    /// exercises/sets with the drafts, mark it done.
    private func save() {
        guard !exercises.isEmpty else { return }
        let wid = workout.id
        let oldSessions = ((try? modelContext.fetch(FetchDescriptor<LiftSession>())) ?? [])
            .filter { $0.workoutID == wid }
        let oldIDs = Set(oldSessions.map(\.id))
        for s in ((try? modelContext.fetch(FetchDescriptor<LiftSet>())) ?? [])
            where oldIDs.contains(s.sessionID) {
            modelContext.delete(s)
        }
        for s in oldSessions { modelContext.delete(s) }

        let base = workout.date == .distantPast ? Date() : workout.date
        for (i, ex) in exercises.enumerated() {
            // Offset each session a second so load() restores exercise order.
            let session = LiftSession(date: base.addingTimeInterval(Double(i)),
                                      exerciseName: ex.name, avgBPM: 0, workoutID: wid)
            modelContext.insert(session)
            for (j, d) in ex.sets.enumerated() {
                modelContext.insert(LiftSet(sessionID: session.id, order: j, reps: d.reps,
                                            weightKg: d.weightKg, inputType: d.inputType,
                                            holdSeconds: d.holdSeconds, addedKg: d.addedKg,
                                            bodyweightKg: d.bodyweightKg))
            }
        }
        if workout.date == .distantPast { workout.date = base }
        workout.state = .done
        saved = modelContext.saveOrLog("WorkoutLiftView.save")
        if saved { dismiss() }
    }

    /// A manual workout closed without ever logging anything shouldn't linger
    /// as an empty card on Today.
    private func cleanupIfAbandoned() {
        guard !saved, workout.source == .manual, workout.durationMin == 0 else { return }
        let wid = workout.id
        let hasData = ((try? modelContext.fetch(FetchDescriptor<LiftSession>())) ?? [])
            .contains { $0.workoutID == wid }
        if !hasData {
            modelContext.delete(workout)
            modelContext.saveOrLog("WorkoutLiftView.cleanup")
        }
    }

    private func kg(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }
}

// MARK: - Walk detail

struct WalkDetailView: View {
    let workout: Workout
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var minutes = 30
    @State private var incline = 0.0
    @State private var saved = false
    @State private var loaded = false

    // Tap-to-type entry.
    @State private var showEdit = false
    @State private var editTitle = ""
    @State private var editText = ""
    @State private var editIsInt = false
    @State private var editApply: ((Double) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        stat("Duration", workout.durationMin > 0 ? "\(workout.durationMin) min" : "\(minutes) min")
                        stat("Avg HR", workout.avgBPM > 0 ? "\u{2665} \(workout.avgBPM)" : "\u{2014}")
                    }
                    if workout.source == .watch {
                        Text("Captured by your Apple Watch")
                            .font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
                            .frame(maxWidth: .infinity)
                    }
                    stepperRow("Minutes", "\(minutes)",
                               dec: { minutes = max(1, minutes - 1) },
                               inc: { minutes += 1 },
                               edit: { promptEdit("Minutes", current: Double(minutes), isInt: true) { minutes = max(1, Int($0)) } })
                    stepperRow("Incline", "\(trimmed(incline))%",
                               dec: { incline = max(0, incline - 0.5) },
                               inc: { incline += 0.5 },
                               edit: { promptEdit("Incline (%)", current: incline, isInt: false) { incline = $0 } })
                    Text("Treadmill incline isn't measurable by the watch \u{2014} add it here and Jeeves factors it into effort.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textMuted)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
                }
                .padding(18)
            }
            .background(Color.bg)
            .navigationTitle(workout.title.isEmpty ? "Walk" : workout.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.tint(Color.accentDeep)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { save() } label: {
                    Text("Save walk")
                        .font(Font.serif(17))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(Color.sageDeep))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 6)
                .background(Color.bg)
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
                Text(editIsInt ? "Type a whole number." : "Type the value.")
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if workout.durationMin > 0 { minutes = workout.durationMin }
                incline = workout.inclinePercent
            }
            .onDisappear {
                // A manual walk closed without saving shouldn't linger.
                if !saved, workout.source == .manual, workout.state != .done {
                    modelContext.delete(workout)
                    modelContext.saveOrLog("WalkDetailView.cleanup")
                }
            }
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k.uppercased())
                .font(.system(size: 10, weight: .bold)).kerning(0.8)
                .foregroundStyle(Color.textMuted)
            Text(v)
                .font(Font.serif(17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.surface))
    }

    private func stepperRow(_ title: String, _ value: String,
                            dec: @escaping () -> Void, inc: @escaping () -> Void,
                            edit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                Button(action: dec) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accent)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.bg))
                }
                .buttonStyle(.plain)
                Button(action: edit) {
                    Text(value)
                        .font(Font.serif(18))
                        .foregroundStyle(Color.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(minWidth: 84)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                Button(action: inc) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accent)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.bg))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.surface))
    }

    private func promptEdit(_ title: String, current: Double, isInt: Bool,
                            apply: @escaping (Double) -> Void) {
        editTitle = title
        editIsInt = isInt
        editText = isInt ? String(Int(current))
                         : (current == current.rounded() ? String(Int(current)) : String(current))
        editApply = apply
        showEdit = true
    }

    private func save() {
        workout.durationMin = minutes
        workout.inclinePercent = incline
        workout.state = .done
        if workout.date == .distantPast { workout.date = Date() }
        saved = modelContext.saveOrLog("WalkDetailView.save")
        if saved { dismiss() }
    }

    private func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}

// MARK: - History (the ONE history: check-in days + workout detail)

/// Sheet wrapper used from the Fitness tab; the Stats tab embeds
/// UnifiedHistoryList directly. Same list either way.
struct WorkoutHistoryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            UnifiedHistoryList()
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }.tint(Color.accentDeep)
                    }
                }
        }
    }
}

/// Day rows — the check-in's verdict (✓ trained / ✗ rest) plus the merged
/// auto∪manual summary — expanding into the day's workout cards, each opening
/// the full log.
struct UnifiedHistoryList: View {
    @Query(sort: \Workout.date, order: .reverse) private var workouts: [Workout]
    @Query private var checkins: [CheckIn]
    @Query private var stretchLogs: [StretchLog]
    @Query private var liftSessions: [LiftSession]
    @Query private var liftSets: [LiftSet]

    @State private var expanded: Set<Date> = []
    @State private var selected: Workout?

    private struct DayRow: Identifiable {
        let id: Date
        let status: CheckInAutoFill.DayStatus
        let workouts: [Workout]
    }

    private var days: [DayRow] {
        let cal = Calendar.current
        var keys = Set<Date>()
        for c in checkins { keys.insert(cal.startOfDay(for: c.date)) }
        for w in workouts where w.state != .live { keys.insert(cal.startOfDay(for: w.date)) }
        for s in stretchLogs { keys.insert(cal.startOfDay(for: s.date)) }
        return keys.sorted(by: >).compactMap { day in
            guard let status = mergedStatus(for: day) else { return nil }
            let dayWorkouts = workouts
                .filter { $0.state != .live && cal.isDate($0.date, inSameDayAs: day) }
                .sorted { $0.date > $1.date }
            return DayRow(id: day, status: status, workouts: dayWorkouts)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if days.isEmpty {
                    Text("Nothing logged yet.")
                        .font(.system(size: 13.5)).foregroundStyle(Color.textMuted)
                        .padding(.vertical, 32)
                }
                ForEach(days) { day in
                    dayCell(day)
                }
            }
            .padding(20)
        }
        .background(Color.bg)
        .sheet(item: $selected) { w in
            NavigationStack { WorkoutHistoryDetail(workout: w) }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: DayRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !day.workouts.isEmpty else { return }
                if expanded.contains(day.id) { expanded.remove(day.id) }
                else { expanded.insert(day.id) }
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(day.status.isRest ? Color.bg : Color.sage)
                        .frame(width: 36, height: 36)
                        .overlay(Circle().stroke(day.status.isRest ? Color.textPrimary.opacity(0.14) : .clear, lineWidth: 1.5))
                        .overlay(
                            Image(systemName: day.status.isRest ? "xmark" : "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(day.status.isRest ? Color.textMuted : .white)
                        )
                    VStack(alignment: .leading, spacing: 0) {
                        Text(prettyDate(day.id)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.textPrimary)
                        Text(day.status.summary).font(.system(size: 12)).foregroundStyle(Color.textSoft).lineLimit(1)
                    }
                    Spacer()
                    if !day.workouts.isEmpty {
                        HStack(spacing: 4) {
                            Text("\(day.workouts.count)")
                                .font(.system(size: 11.5, weight: .bold)).foregroundStyle(Color.sageDeep)
                            Image(systemName: expanded.contains(day.id) ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.textMuted)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Capsule().fill(Color.sageLight))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if expanded.contains(day.id) {
                VStack(spacing: 8) {
                    ForEach(day.workouts, id: \.id) { w in
                        WorkoutCard(workout: w, summary: liftSummary(w)) { selected = w }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    // MARK: merged day status

    private func mergedStatus(for day: Date) -> CheckInAutoFill.DayStatus? {
        let cal = Calendar.current
        let facts = workouts
            .filter { cal.isDate($0.date, inSameDayAs: day) }
            .map { CheckInAutoFill.WorkoutFact(type: $0.type, finished: $0.state != .live,
                                               durationMin: $0.durationMin,
                                               incline: $0.inclinePercent) }
        let stretches = stretchLogs.filter { cal.isDate($0.date, inSameDayAs: day) }.count
        let manual = checkins.first { cal.isDate($0.date, inSameDayAs: day) }.map {
            CheckInAutoFill.manualFacts(workedOut: $0.workedOut, weightTraining: $0.weightTraining,
                                        stretching: $0.stretching, mobility: $0.mobility,
                                        cardio: $0.cardio, cardioType: $0.cardioType,
                                        cardioDuration: $0.cardioDuration, cardioIncline: $0.cardioIncline)
        }
        return CheckInAutoFill.mergedDay(auto: CheckInAutoFill.derive(facts, stretchCount: stretches),
                                         manual: manual)
    }

    private func liftSummary(_ w: Workout) -> String? {
        guard w.type == .lift else { return nil }
        let sessions = liftSessions.filter { $0.workoutID == w.id }
        guard !sessions.isEmpty else { return nil }
        return sessions
            .map { s in "\(s.exerciseName) (\(liftSets.filter { $0.sessionID == s.id }.count)\u{00D7})" }
            .joined(separator: " \u{00B7} ")
    }

    private func prettyDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEE, d MMM"
        return f.string(from: d)
    }
}

/// The full log of one past workout, read-only.
struct WorkoutHistoryDetail: View {
    let workout: Workout
    @Query private var liftSessions: [LiftSession]
    @Query private var liftSets: [LiftSet]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    stat("Duration", workout.durationMin > 0 ? "\(workout.durationMin) min" : "\u{2014}")
                    stat("Avg HR", workout.avgBPM > 0 ? "\u{2665} \(workout.avgBPM)" : "\u{2014}")
                    switch workout.type {
                    case .lift: stat("Tonnage", "\(Int(totalTonnage.rounded())) kg")
                    case .walk: stat("Incline", "\(trimmed(workout.inclinePercent))%")
                    case .run:  stat("Distance", String(format: "%.1f km", workout.distanceKm))
                    }
                }
                Text(sourceLine)
                    .font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity)

                switch workout.type {
                case .lift:
                    ForEach(sessions, id: \.id) { s in
                        exerciseBlock(s)
                    }
                case .walk:
                    infoBlock("Walked \(workout.durationMin) min at \(trimmed(workout.inclinePercent))% incline")
                case .run:
                    infoBlock(String(format: "%.1f km \u{00B7} run/walk intervals \u{00B7} logged by the run tool", workout.distanceKm))
                }
            }
            .padding(18)
        }
        .background(Color.bg)
        .navigationTitle(workout.title.isEmpty ? "Workout" : workout.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sessions: [LiftSession] {
        liftSessions.filter { $0.workoutID == workout.id }.sorted { $0.date < $1.date }
    }

    private func sets(for s: LiftSession) -> [LiftSet] {
        liftSets.filter { $0.sessionID == s.id }.sorted { $0.order < $1.order }
    }

    private var totalTonnage: Double {
        sessions.reduce(0) { $0 + LiftMath.sessionTonnage(sets(for: $1)) }
    }

    private func exerciseBlock(_ s: LiftSession) -> some View {
        let ss = sets(for: s)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(s.exerciseName)
                    .font(Font.serif(17, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(Int(LiftMath.sessionTonnage(ss).rounded())) kg")
                    .font(.system(size: 12)).foregroundStyle(Color.textMuted)
                    .monospacedDigit()
            }
            ForEach(Array(ss.enumerated()), id: \.element.id) { i, set in
                HStack(spacing: 10) {
                    Text("\(i + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.sageDeep)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.sageLight))
                    Text(setLine(set))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textPrimary)
                        .monospacedDigit()
                    Spacer()
                    Text("\(Int(LiftMath.setTonnage(set).rounded())) kg")
                        .font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
    }

    private func setLine(_ s: LiftSet) -> String {
        switch s.inputType {
        case .weighted:   return "\(s.reps) reps \u{00D7} \(trimmed(s.weightKg)) kg"
        case .bodyweight: return "\(s.reps) reps \u{00D7} bw \(trimmed(s.bodyweightKg))\(s.addedKg > 0 ? " +\(trimmed(s.addedKg))" : "") kg"
        case .isometric:  return "\(s.holdSeconds)s hold"
        }
    }

    private func infoBlock(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 14))
            .foregroundStyle(Color.textPrimary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
    }

    private var sourceLine: String {
        switch workout.source {
        case .watch:  return "\u{231A} Duration & heart rate captured by your Apple Watch"
        case .phone:  return "\u{1F4F1} Logged by the phone's run tool"
        case .manual: return "\u{270D}\u{FE0E} Logged manually \u{2014} no watch data"
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k.uppercased())
                .font(.system(size: 10, weight: .bold)).kerning(0.8)
                .foregroundStyle(Color.textMuted)
            Text(v)
                .font(Font.serif(16, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.surface))
    }

    private func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}
