//
//  ContentView.swift
//  Jeeves
//
//  Fitness accountability module: daily check-in, monthly progress, history.
//

import SwiftUI
import SwiftData

// MARK: - Palette (matches the web prototype's design tokens)

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    static let bg = Color(hex: "F5EAD8")
    static let surface = Color(hex: "EBDDC5")
    static let surfaceDeep = Color(hex: "DCD3C4")
    static let textPrimary = Color(hex: "201E1D")
    static let textSoft = Color(hex: "645C50")
    // Darkened from #A19786 (WCAG 2.42:1 on bg — failed AA) to clear 4.5:1 on bg
    // (now 4.71) while staying a warm-taupe tier lighter than textSoft. On cards
    // (surface) it reaches 4.18 — AA for large/semibold captions; use textSoft for
    // small regular text on cards. For strict AA everywhere use #675E4E (converges
    // toward textSoft).
    static let textMuted = Color(hex: "6E6759")
    static let accent = Color(hex: "C67139")
    static let accentDeep = Color(hex: "8C491A")
    static let sage = Color(hex: "7A8A5E")
    static let sageDeep = Color(hex: "56633F")
    static let sageLight = Color(hex: "E1EECC")
}

// Editorial serif display face — Georgia, the PT Serif stand-in used in the
// new UI design. Screen titles, activity names, and big stat numbers render in
// it; body text, labels, and eyebrows stay in the system sans for legibility.
// (Georgia ships with iOS, so nothing needs bundling; swap the family name here
// if real PT Serif files are ever added.)
extension Font {
    static func serif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("Georgia", size: size).weight(weight)
    }
    /// Kept for existing call sites; now resolves to the serif display face.
    static func heading(_ size: CGFloat) -> Font {
        serif(size)
    }
}

extension View {
    /// Applies the Jeeves warm theme to a native Form/List so it stops showing
    /// Apple's default gray-grouped look: tan page background, terracotta
    /// accent on controls. Pair each Section with `.listRowBackground(Color.surface)`
    /// so the rows are warm cards instead of white.
    func jeevesFormChrome() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.bg)
            .tint(Color.accent)
    }
}

private let monthlyGoal = 20

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \CheckIn.date, order: .reverse) private var checkins: [CheckIn]
    // The auto-derive layer: logged workouts + stretch sessions tick the
    // check-in (and feed the streak) on their own.
    @Query private var allWorkouts: [Workout]
    @Query private var allStretchLogs: [StretchLog]

    enum Tab { case jeeves, planner, tasks, fitness, library, stats }
    enum FitnessSheet: String, Identifiable { case run, lift, stretch; var id: String { rawValue } }
    enum StatsSub: CaseIterable { case progress, history; var label: String { self == .progress ? "Progress" : "History" } }

    @State private var tab: Tab = .planner
    @State private var fitnessSheet: FitnessSheet?
    @State private var statsSub: StatsSub = .progress
    @State private var selectedDate: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date())!.startOfDay
    @State private var showDatePicker = false

    // Working copy of the fields for the selected date, edited in place then saved.
    @State private var workedOut: Bool? = nil
    @State private var weightTraining = false
    @State private var stretching = false
    @State private var mobility = false
    @State private var cardio = false
    @State private var cardioType: String? = nil
    @State private var cardioDuration: String = ""
    @State private var cardioIncline: String = ""
    @State private var justSaved = false
    @State private var isEditingCheckin = true

    private var realYesterday: Date {
        // Calendar day arithmetic, not −86400s: a DST-change day isn't 24h.
        Calendar.current.date(byAdding: .day, value: -1, to: Date())?.startOfDay ?? Date().startOfDay
    }
    private var realToday: Date { Date().startOfDay }

    private func entry(for date: Date) -> CheckIn? {
        // Match by calendar day, not exact Date equality (robust across DST / TZ).
        let cal = Calendar.current
        return checkins.first { cal.isDate($0.date, inSameDayAs: date) }
    }

    private var yesterdayDone: Bool { entry(for: realYesterday) != nil }
    private var todayDone: Bool { entry(for: realToday) != nil }

    /// The auto-derived check-in layer for a date, from its logged workouts +
    /// stretch sessions.
    private func autoDerived(for date: Date) -> CheckInAutoFill.Derived {
        let cal = Calendar.current
        let facts = allWorkouts
            .filter { cal.isDate($0.date, inSameDayAs: date) }
            .map { CheckInAutoFill.WorkoutFact(type: $0.type, finished: $0.state != .live,
                                               durationMin: $0.durationMin,
                                               incline: $0.inclinePercent) }
        let stretches = allStretchLogs.filter { cal.isDate($0.date, inSameDayAs: date) }.count
        return CheckInAutoFill.derive(facts, stretchCount: stretches)
    }

    /// Merged (auto ∪ manual) status for a date — what the streak, history and
    /// summaries read. Nil when the day has nothing at all.
    private func mergedStatus(for date: Date) -> CheckInAutoFill.DayStatus? {
        let manual = entry(for: date).map {
            CheckInAutoFill.manualFacts(workedOut: $0.workedOut, weightTraining: $0.weightTraining,
                                        stretching: $0.stretching, mobility: $0.mobility,
                                        cardio: $0.cardio, cardioType: $0.cardioType,
                                        cardioDuration: $0.cardioDuration, cardioIncline: $0.cardioIncline)
        }
        return CheckInAutoFill.mergedDay(auto: autoDerived(for: date), manual: manual)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .jeeves: JeevesChatView()
                case .planner: DayPlannerView()
                case .fitness: fitnessTab
                case .library: LibraryView()
                case .tasks: tasksTab
                case .stats: statsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider().overlay(Color.textPrimary.opacity(0.14))
            tabBar
        }
        .background(Color.bg)
        .onAppear {
            loadFields(for: selectedDate)
            // Any plan generation still "pending" from a prior run never
            // returned (crash/kill/hang) — record that truthfully.
            PlanDiagnostics.sweepAbandoned(context: modelContext)
            // Collapse any duplicate per-day plan rows (pre-fix races / CloudKit merges).
            DailyPlanState.dedupe(in: modelContext)
            // Refresh the full iCloud Drive mirror on launch: JSON state +
            // heartbeat + logs, plus the raw-SQLite fallback (launch has time).
            SyncOutbox.exportAll(context: modelContext, includeRawBackup: true)
        }
        .onChange(of: selectedDate) { _, newDate in loadFields(for: newDate) }
        .onChange(of: scenePhase) { _, phase in
            // Reliable path: whenever the app comes to the foreground, re-price
            // any commute departing within the next 90 min against live traffic
            // and nudge the leave-by if it moved.
            if phase == .active {
                Task {
                    await CommuteRefresh.run(context: modelContext)
                    CommuteBackgroundRefresh.scheduleNext(context: modelContext)
                    // Backstop for the overnight auto-planner: if the system
                    // never granted a background slot, fill any missing upcoming
                    // day now so today's plan is ready the moment they open the
                    // app. A no-op once the window is already planned.
                    await AutoPlanService.ensureUpcomingPlans(context: modelContext)
                    AutoPlanService.scheduleNext(context: modelContext)
                }
            }
            if phase == .background {
                // Snapshot the just-finished session to iCloud (fast JSON path;
                // the raw-SQLite fallback is left to the next launch to avoid a
                // partial copy if the OS suspends us mid-write).
                SyncOutbox.exportAll(context: modelContext, includeRawBackup: false)
            }
        }
    }

    // MARK: Per-tab chrome

    /// One slim header per tab. Replaces the old global "Fitness" header,
    /// which stacked above each module's own header and burned ~15% of every
    /// screen on chrome before content started.
    private func moduleHeader(_ title: String, _ icon: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accent)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: icon).foregroundStyle(.white).font(.system(size: 13)))
                Text(title).font(.heading(18)).foregroundStyle(Color.textPrimary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
    }

    private var streakChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill").font(.system(size: 12)).foregroundStyle(Color.sageDeep)
            Text("\(streak) day streak").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.sageDeep)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Color.sageLight))
    }

    private var fitnessTab: some View {
        VStack(spacing: 0) {
            moduleHeader("Fitness", "figure.strengthtraining.traditional") {
                if streak > 0 { streakChip }
            }
            Divider().overlay(Color.textPrimary.opacity(0.14))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    checkinView            // the original daily check-in, kept as the core
                    WorkoutTodaySection { fitnessSheet = .run }   // Today feed + History
                    stretchLink
                }
                .padding(20)
            }
        }
        .sheet(item: $fitnessSheet) { sheet in
            switch sheet {
            case .run:     RunView()
            case .lift:    LiftView()
            case .stretch: StretchView()
            }
        }
    }

    /// Stretch stays its own guided flow outside the Workout feed (runs, lifts
    /// and walks all live on the Today cards now).
    private var stretchLink: some View {
        fitnessRow("Stretch & mobility", "Guided, timed holds", "figure.flexibility") { fitnessSheet = .stretch }
    }

    private func fitnessRow(_ title: String, _ subtitle: String, _ icon: String,
                            _ tapped: @escaping () -> Void) -> some View {
        Button(action: tapped) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18))
                    .foregroundStyle(Color.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Font.serif(15, weight: .semibold)).foregroundStyle(Color.textPrimary)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 15).fill(Color.surface))
        }
        .buttonStyle(.plain)
    }

    private var tasksTab: some View {
        VStack(spacing: 0) {
            moduleHeader("Tasks", "checklist") { EmptyView() }
            Divider().overlay(Color.textPrimary.opacity(0.14))
            TasksView()
        }
    }

    /// Progress + History merged under one tab (frees the slot for Tasks), split
    /// by a lightweight sub-toggle so both keep their full screen.
    private var statsTab: some View {
        VStack(spacing: 0) {
            moduleHeader("Stats", "chart.bar.fill") {
                if streak > 0 { streakChip }
            }
            Divider().overlay(Color.textPrimary.opacity(0.14))
            HStack(spacing: 4) {
                ForEach(StatsSub.allCases, id: \.self) { s in
                    Button { statsSub = s } label: {
                        Text(s.label)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(statsSub == s ? .white : Color.textSoft)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(statsSub == s ? Color.accent : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.textPrimary.opacity(0.05)))
            .padding(.horizontal, 16).padding(.vertical, 8)

            if statsSub == .progress {
                ScrollView { progressView.padding(20) }
            } else {
                historyView
            }
        }
    }

    // MARK: Check-in tab

    private var checkinView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !yesterdayDone && selectedDate != realYesterday {
                banner(title: "Yesterday's check-in is waiting", subtitle: prettyDate(realYesterday),
                       bg: Color.surface, fg: Color.textPrimary, iconColor: Color.accent) {
                    selectedDate = realYesterday
                }
            } else if yesterdayDone && !todayDone && selectedDate != realToday {
                banner(title: "Log today's check-in", subtitle: prettyDate(realToday),
                       bg: Color.sageLight, fg: Color.sageDeep, iconColor: Color.sageDeep) {
                    selectedDate = realToday
                }
            }

            HStack {
                Button { showDatePicker.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 14)).foregroundStyle(Color.textSoft)
                        Text(prettyDate(selectedDate)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.textSoft)
                    }
                }
                Spacer()
            }
            .padding(.bottom, showDatePicker ? 8 : 18)

            if showDatePicker {
                DatePicker("", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(.bottom, 16)
            }

            if isEditingCheckin {
                let auto = autoDerived(for: selectedDate)

                Text("Did you work out?").font(.heading(17)).foregroundStyle(Color.textPrimary).padding(.bottom, 14)

                if auto.hasAnything {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13)).foregroundStyle(Color.sageDeep)
                        Text("Already logged from your workouts \u{2014} sealed ticks below came from them.")
                            .font(.system(size: 12)).foregroundStyle(Color.textSoft)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.sageLight))
                    .padding(.bottom, 14)
                }

                HStack(spacing: 10) {
                    choiceButton("Yes", selected: workedOut == true, fillWhenSelected: Color.accent) {
                        setWorkedOut(true)
                    }
                    choiceButton("No", selected: workedOut == false, fillWhenSelected: Color.surfaceDeep) {
                        setWorkedOut(false)
                    }
                }
                .padding(.bottom, 22)

                if workedOut == true {
                    Text("WHAT DID YOU DO")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.textMuted)
                        .padding(.bottom, 10)

                    FlowChips {
                        chip("Weight training", $weightTraining, locked: auto.weightTraining)
                        chip("Stretching", $stretching, locked: auto.stretching)
                        chip("Mobility", $mobility)
                        chip("Cardio", $cardio, locked: auto.cardio)
                    }
                    .padding(.bottom, (cardio || auto.cardio) ? 16 : 4)

                    if auto.cardio {
                        // Cardio came from a logged workout — its numbers live
                        // there, not in manual fields.
                        HStack(spacing: 8) {
                            Image(systemName: auto.cardioIsRun ? "figure.run" : "figure.walk")
                                .font(.system(size: 14)).foregroundStyle(Color.sageDeep)
                            Text(autoCardioLine(auto))
                                .font(.system(size: 13)).foregroundStyle(Color.textPrimary)
                            Spacer()
                            Text("edit the workout to change")
                                .font(.system(size: 10.5)).foregroundStyle(Color.textMuted)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
                    } else if cardio {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("CARDIO TYPE").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.textMuted)
                            HStack(spacing: 8) {
                                cardioTypeButton("Running")
                                cardioTypeButton("Inclined Walk")
                            }
                            if cardioType != nil {
                                HStack(spacing: 10) {
                                    numberField("Duration (min)", text: $cardioDuration)
                                    numberField("Incline (%)", text: $cardioIncline, allowDecimal: true)
                                }
                            }
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
                    }
                } else if workedOut == false {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Color.textMuted)
                        Text("Logged as a rest day").font(.system(size: 13.5)).foregroundStyle(Color.textSoft)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
                }

                if workedOut != nil {
                    Button {
                        save()
                        justSaved = true
                        isEditingCheckin = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { justSaved = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                            Text("Save check-in").font(.system(size: 14.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accent))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)
                }
            } else {
                checkinStatsView
            }
        }
        .onChange(of: cardioDuration) { _, newValue in
            let filtered = sanitizeInteger(newValue)
            if filtered != newValue { cardioDuration = filtered }
        }
        .onChange(of: cardioIncline) { _, newValue in
            let filtered = sanitizeDecimal(newValue)
            if filtered != newValue { cardioIncline = filtered }
        }
    }

    /// Shown once the selected day already has a saved check-in — the form
    /// steps aside for a quick summary plus the stats it feeds (streak,
    /// this month's count, goal progress), with an Edit affordance to go back.
    private var checkinStatsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if justSaved {
                Text("Saved").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.sageDeep)
            }

            if let s = mergedStatus(for: selectedDate) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(s.isRest ? Color.bg : Color.sage)
                        .frame(width: 40, height: 40)
                        .overlay(Circle().stroke(s.isRest ? Color.textPrimary.opacity(0.14) : .clear, lineWidth: 1.5))
                        .overlay(
                            Image(systemName: s.isRest ? "xmark" : "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(s.isRest ? Color.textMuted : .white)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.isRest ? "Rest day" : "Logged").font(.system(size: 14.5, weight: .bold)).foregroundStyle(Color.textPrimary)
                        if s.summary != (s.isRest ? "Rest day" : "Logged") {
                            Text(s.summary).font(.system(size: 12.5)).foregroundStyle(Color.textSoft)
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
            }

            HStack(spacing: 10) {
                statCard("Streak", "\(streak)")
                statCard("This month", "\(monthDaysCount)")
                statCard("Goal", "\(Int(progressPct * 100))%")
            }

            Button {
                isEditingCheckin = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil").font(.system(size: 13, weight: .semibold))
                    Text("Edit check-in").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 16).stroke(Color.textPrimary.opacity(0.14), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
    }

    private func banner(title: String, subtitle: String, bg: Color, fg: Color, iconColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .bold)).foregroundStyle(fg)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.textSoft)
                }
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 14)).foregroundStyle(iconColor)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 16).fill(bg))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 16)
    }

    private func choiceButton(_ label: String, selected: Bool, fillWhenSelected: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(selected && fillWhenSelected == .accent ? .white : Color.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(selected ? fillWhenSelected : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(selected ? .clear : Color.textPrimary.opacity(0.14), lineWidth: 1.5)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func cardioTypeButton(_ type: String) -> some View {
        Button {
            cardioType = type
        } label: {
            Text(type == "Running" ? "Running" : "Inclined walk")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(cardioType == type ? .white : Color.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(cardioType == type ? Color.accent : Color.bg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(cardioType == type ? .clear : Color.textPrimary.opacity(0.14), lineWidth: 1.5)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    /// A locked chip is auto-derived from a logged workout: shown ticked, not
    /// un-tickable (delete the workout instead). Manual chips toggle freely.
    private func chip(_ label: String, _ isOn: Binding<Bool>, locked: Bool = false) -> some View {
        let on = locked || isOn.wrappedValue
        return Button {
            guard !locked else { return }
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                if on {
                    Image(systemName: locked ? "checkmark.seal.fill" : "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
                Text(label).font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(on ? .white : Color.textPrimary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(
                Capsule().fill(on ? Color.sage : .clear)
                    .overlay(Capsule().stroke(on ? .clear : Color.textPrimary.opacity(0.14), lineWidth: 1.5))
            )
        }
        .buttonStyle(.plain)
    }

    private func numberField(_ label: String, text: Binding<String>, allowDecimal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.textMuted)
            TextField("0", text: filteredBinding(text, allowDecimal: allowDecimal))
                .keyboardType(allowDecimal ? .decimalPad : .numberPad)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.bg))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.textPrimary.opacity(0.14), lineWidth: 1.5))
        }
        .frame(maxWidth: .infinity)
    }

    /// Strips anything that isn't a digit (and, if allowed, a single decimal point)
    /// so pasted or hardware-keyboard input can't sneak in letters/symbols.
    private func filteredBinding(_ source: Binding<String>, allowDecimal: Bool) -> Binding<String> {
        Binding<String>(
            get: { source.wrappedValue },
            set: { newValue in
                var filtered = newValue.filter { $0.isNumber || ($0 == "." && allowDecimal) }
                if allowDecimal {
                    let parts = filtered.components(separatedBy: ".")
                    if parts.count > 2 {
                        filtered = parts[0] + "." + parts.dropFirst().joined()
                    }
                }
                source.wrappedValue = filtered
            }
        )
    }

    // MARK: Progress tab

    /// Every distinct day this month with either a check-in or logged activity.
    private var monthDaysCount: Int {
        let cal = Calendar.current
        var days = Set<Date>()
        for c in checkins where cal.isDate(c.date, equalTo: selectedDate, toGranularity: .month) {
            days.insert(cal.startOfDay(for: c.date))
        }
        for w in allWorkouts where cal.isDate(w.date, equalTo: selectedDate, toGranularity: .month) {
            days.insert(cal.startOfDay(for: w.date))
        }
        for s in allStretchLogs where cal.isDate(s.date, equalTo: selectedDate, toGranularity: .month) {
            days.insert(cal.startOfDay(for: s.date))
        }
        return days.filter { mergedStatus(for: $0)?.qualifies == true }.count
    }

    private var progressPct: Double {
        min(1.0, Double(monthDaysCount) / Double(monthlyGoal))
    }

    /// Consecutive qualifying days ending at the selected date. A logged
    /// workout alone keeps the day alive — no check-in tap needed.
    private var streak: Int {
        var count = 0
        var cursor = selectedDate
        let cal = Calendar.current
        while let s = mergedStatus(for: cursor), s.qualifies {
            count += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }

    private var progressView: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.surfaceDeep, lineWidth: 10).frame(width: 112, height: 112)
                Circle()
                    .trim(from: 0, to: progressPct)
                    .stroke(Color.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 112, height: 112)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: progressPct)
                VStack(spacing: 0) {
                    Text("\(monthDaysCount)").font(.heading(24)).foregroundStyle(Color.textPrimary)
                    Text("of \(monthlyGoal) days").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.textMuted)
                }
            }

            Text(selectedDate.formatted(.dateTime.month(.wide).year())).font(.heading(16)).foregroundStyle(Color.textPrimary)

            Text(monthDaysCount >= monthlyGoal
                 ? "Goal reached this month"
                 : "\(monthlyGoal - monthDaysCount) more workout day\(monthlyGoal - monthDaysCount == 1 ? "" : "s") to hit your goal")
                .font(.system(size: 13)).foregroundStyle(Color.textSoft).multilineTextAlignment(.center)

            HStack(spacing: 10) {
                statCard("This month", "\(monthDaysCount)")
                statCard("Streak", "\(streak)")
                statCard("Total logged", "\(checkins.count)")
            }
        }
        .padding(.top, 12)
    }

    private func statCard(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.heading(20)).foregroundStyle(Color.accentDeep)
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    // MARK: History tab

    /// The ONE history: day rows (check-in verdict + merged summary) that
    /// expand into the day's workout cards. Fitness's History button opens the
    /// same list as a sheet.
    private var historyView: some View {
        UnifiedHistoryList()
    }

    /// One line for cardio that came from a logged workout.
    private func autoCardioLine(_ auto: CheckInAutoFill.Derived) -> String {
        var s = auto.cardioIsRun ? "Run" : "Walk"
        if let d = auto.cardioDuration { s += " \u{00B7} \(Int(d)) min" }
        if let i = auto.cardioIncline { s += " \u{00B7} \(formatNumber(i))%" }
        return s
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.jeeves, "sparkles", "Jeeves")
            tabButton(.planner, "calendar", "Planner")
            tabButton(.tasks, "checklist", "Tasks")
            tabButton(.fitness, "figure.strengthtraining.traditional", "Fitness")
            tabButton(.library, "books.vertical.fill", "Library")
            tabButton(.stats, "chart.bar.fill", "Stats")
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
    }

    private func tabButton(_ target: Tab, _ icon: String, _ label: String) -> some View {
        Button { tab = target } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17))
                    .foregroundStyle(tab == target ? Color.accent : Color.textMuted)
                Text(label).font(.system(size: 10.5, weight: tab == target ? .bold : .medium))
                    .foregroundStyle(tab == target ? Color.textPrimary : Color.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: Data plumbing

    private func loadFields(for date: Date) {
        if let e = entry(for: date) {
            workedOut = e.workedOut
            weightTraining = e.weightTraining
            stretching = e.stretching
            mobility = e.mobility
            cardio = e.cardio
            cardioType = e.cardioType
            cardioDuration = e.cardioDuration.map { String(Int($0)) } ?? ""
            cardioIncline = e.cardioIncline.map { formatNumber($0) } ?? ""
            isEditingCheckin = false
        } else {
            workedOut = nil
            weightTraining = false
            stretching = false
            mobility = false
            cardio = false
            cardioType = nil
            cardioDuration = ""
            cardioIncline = ""
            isEditingCheckin = true
        }
    }

    private func setWorkedOut(_ val: Bool) {
        workedOut = val
        if !val {
            weightTraining = false
            stretching = false
            mobility = false
            cardio = false
            cardioType = nil
        }
    }

    private func save() {
        guard let workedOut else { return }
        let day = selectedDate.startOfDay

        if let existing = entry(for: day) {
            existing.workedOut = workedOut
            existing.weightTraining = weightTraining
            existing.stretching = stretching
            existing.mobility = mobility
            existing.cardio = cardio
            existing.cardioType = cardioType
            existing.cardioDuration = Double(cardioDuration)
            existing.cardioIncline = Double(cardioIncline)
        } else {
            let newEntry = CheckIn(
                date: day,
                workedOut: workedOut,
                weightTraining: weightTraining,
                stretching: stretching,
                mobility: mobility,
                cardio: cardio,
                cardioType: cardioType,
                cardioDuration: Double(cardioDuration),
                cardioIncline: Double(cardioIncline)
            )
            modelContext.insert(newEntry)
        }
        modelContext.saveOrLog()
    }

    private func prettyDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Shows "2" instead of "2.0", but keeps real decimals like "2.5".
    private func formatNumber(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    /// Keeps only digits — used for whole-number fields like duration.
    private func sanitizeInteger(_ input: String) -> String {
        String(input.filter { $0.isNumber })
    }

    /// Keeps digits and at most one decimal point — used for the incline field.
    private func sanitizeDecimal(_ input: String) -> String {
        var seenDot = false
        var result = ""
        for ch in input {
            if ch.isNumber {
                result.append(ch)
            } else if ch == "." && !seenDot {
                seenDot = true
                result.append(ch)
            }
        }
        return result
    }
}

// MARK: - Simple wrapping layout for the chip row

struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        // For simplicity this wraps in a horizontal scroll; swap for a custom
        // Layout (iOS 16+) later if you want true multi-line wrapping.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [CheckIn.self, JobApplication.self, PrepSession.self, LeisureLog.self, DailyPlanState.self, Book.self, ReadingLog.self], inMemory: true)
}
