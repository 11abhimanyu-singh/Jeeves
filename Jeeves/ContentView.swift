//
//  ContentView.swift
//  Jeeves
//
//  Fitness accountability module: daily check-in, monthly progress, history.
//

import SwiftUI
import UIKit   // UIFontMetrics — the only way to scale an arbitrary point size
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
    /// The text style a given point size should scale against. Picking one per
    /// size band keeps the app's existing rhythm — a 10 pt eyebrow and a 40 pt
    /// stat shouldn't grow at the same rate — while still tracking the user's
    /// setting.
    nonisolated static func metricStyle(for size: CGFloat) -> UIFont.TextStyle {
        switch size {
        // 11.5, not 11: the floor is 11, so a `..<11` band would be dead code
        // and the app's smallest text would scale as caption1 instead of the
        // smallest style there is.
        case ..<11.5:  return .caption2
        case ..<12.5:  return .caption1
        case ..<14:    return .footnote
        case ..<15.5:  return .subheadline
        case ..<17.5:  return .callout
        case ..<20:    return .title3
        case ..<26:    return .title2
        case ..<34:    return .title1
        default:       return .largeTitle
        }
    }

    /// Smallest size the app will render. Below this, text stops being
    /// readable for a lot of people — and the 8.5 pt time-zone label was the
    /// one that distinguishes 15:00 Thimphu from 15:00 IST.
    nonisolated static let minimumPointSize: CGFloat = 11

    /// Scaling replacement for `.system(size:)`. `Font.system(size:)` is fixed
    /// forever — there is no `relativeTo:` for it — so the point size is run
    /// through UIFontMetrics, which is what Dynamic Type actually uses. At the
    /// default text size `scaledValue(for:)` is the identity, so this changes
    /// nothing visually until the user asks it to.
    static func ui(_ size: CGFloat,
                   weight: Font.Weight = .regular,
                   design: Font.Design = .default) -> Font {
        let floored = max(size, minimumPointSize)
        let scaled = UIFontMetrics(forTextStyle: metricStyle(for: floored))
            .scaledValue(for: floored)
        return .system(size: scaled, weight: weight, design: design)
    }

    /// The editorial serif. `.custom(_:size:relativeTo:)` DOES scale, unlike
    /// the system-font initialiser — this one line is what makes 81 display
    /// call sites respond to Dynamic Type.
    static func serif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("Georgia", size: max(size, minimumPointSize),
                relativeTo: textStyle(for: max(size, minimumPointSize)))
            .weight(weight)
    }

    /// Kept for existing call sites; now resolves to the serif display face.
    static func heading(_ size: CGFloat) -> Font {
        serif(size)
    }

    /// SwiftUI's mirror of `metricStyle(for:)`, for `relativeTo:`.
    nonisolated static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5:  return .caption2   // mirrors metricStyle's floor band
        case ..<12.5:  return .caption
        case ..<14:    return .footnote
        case ..<15.5:  return .subheadline
        case ..<17.5:  return .callout
        case ..<20:    return .title3
        case ..<26:    return .title2
        case ..<34:    return .title
        default:       return .largeTitle
        }
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

    // Progress became the landing screen; Stats moved into the hamburger and
    // Jeeves became a floating bubble, so neither is a tab any more.
    enum Tab { case home, planner, tasks, fitness, library }
    enum FitnessSheet: String, Identifiable { case run, lift, stretch; var id: String { rawValue } }

    @State private var tab: Tab = .home
    @State private var fitnessSheet: FitnessSheet?
    @State private var navigator = AppNavigator()
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
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case .home: homeTab
                    case .planner: DayPlannerView()
                    case .fitness: fitnessTab
                    case .library: LibraryView()
                    case .tasks: tasksTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Reserve the bubble's corner instead of floating over it: a
                // 56pt circle at the trailing edge sat on top of whatever ended
                // the scroll, and on Tasks that was the last row's delete
                // button — tapping delete opened chat, with no way to scroll
                // the row clear.
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 76) }

                Divider().overlay(Color.textPrimary.opacity(0.14))
                tabBar
            }

            // Jeeves follows every screen instead of owning a tab.
            ChatBubble()
                .padding(.trailing, 18)
                .padding(.bottom, 82)
        }
        .background(Color.bg)
        .environment(navigator)
        .sheet(isPresented: Binding(get: { navigator.showSettings },
                                    set: { navigator.showSettings = $0 })) {
            NavigationStack { SettingsView() }
        }
        .sheet(item: Binding(get: { navigator.statsScreen },
                             set: { navigator.statsScreen = $0 })) { screen in
            StatsScreenView(screen: screen) { navigator.statsScreen = nil }
                .environment(navigator)
        }
        .sheet(isPresented: Binding(get: { navigator.chatPresented },
                                    set: { navigator.chatPresented = $0 })) {
            JeevesChatView(onMinimise: { navigator.chatPresented = false })
                .environment(navigator)
        }
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
            // Notification actions need a context to write through.
            NotificationDelegate.modelContext = modelContext
            // A workout can go stale while the app is closed, so the watchdog
            // sweeps on launch as well as on every foreground.
            Task { await WorkoutWatchdog.sweep(context: modelContext) }
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
                    await WorkoutWatchdog.sweep(context: modelContext)
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
                AppMenuButton()
                Circle()
                    .fill(Color.accent)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: icon).foregroundStyle(.white).font(.ui(13)))
                Text(title).font(.heading(18)).foregroundStyle(Color.textPrimary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
    }

    private var streakChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill").font(.ui(12)).foregroundStyle(Color.sageDeep)
            Text("\(streak) day streak").font(.ui(12.5, weight: .semibold)).foregroundStyle(Color.sageDeep)
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
                Image(systemName: icon).font(.ui(18))
                    .foregroundStyle(Color.accentDeep).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Font.serif(15, weight: .semibold)).foregroundStyle(Color.textPrimary)
                    Text(subtitle).font(.ui(11.5)).foregroundStyle(Color.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.ui(13, weight: .semibold))
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

    /// The welcome screen. Progress used to be buried as a sub-tab of Stats —
    /// it is the thing worth seeing on open, so it opens.
    private var homeTab: some View {
        VStack(spacing: 0) {
            moduleHeader("Progress", "chart.line.uptrend.xyaxis") {
                if streak > 0 { streakChip }
            }
            Divider().overlay(Color.textPrimary.opacity(0.14))
            ScrollView { progressView.padding(20) }
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
                        Image(systemName: "calendar").font(.ui(14)).foregroundStyle(Color.textSoft)
                        Text(prettyDate(selectedDate)).font(.ui(13.5, weight: .semibold)).foregroundStyle(Color.textSoft)
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
                            .font(.ui(13)).foregroundStyle(Color.sageDeep)
                        Text("Already logged from your workouts \u{2014} sealed ticks below came from them.")
                            .font(.ui(12)).foregroundStyle(Color.textSoft)
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
                        .font(.ui(11.5, weight: .semibold))
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
                                .font(.ui(14)).foregroundStyle(Color.sageDeep)
                            Text(autoCardioLine(auto))
                                .font(.ui(13)).foregroundStyle(Color.textPrimary)
                            Spacer()
                            Text("edit the workout to change")
                                .font(.ui(10.5)).foregroundStyle(Color.textMuted)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
                    }
                    // A manually recorded cardio session stays editable even when
                    // a workout also logged cardio — they can be different
                    // sessions (an untracked run plus a logged walk).
                    if cardio {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("CARDIO TYPE").font(.ui(11, weight: .semibold)).foregroundStyle(Color.textMuted)
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
                        Image(systemName: "xmark").font(.ui(13)).foregroundStyle(Color.textMuted)
                        Text("Logged as a rest day").font(.ui(13.5)).foregroundStyle(Color.textSoft)
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
                            Image(systemName: "checkmark").font(.ui(14, weight: .bold))
                            Text("Save check-in").font(.ui(14.5, weight: .semibold))
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
                Text("Saved").font(.ui(12.5, weight: .semibold)).foregroundStyle(Color.sageDeep)
            }

            if let s = mergedStatus(for: selectedDate) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(s.isRest ? Color.bg : Color.sage)
                        .frame(width: 40, height: 40)
                        .overlay(Circle().stroke(s.isRest ? Color.textPrimary.opacity(0.14) : .clear, lineWidth: 1.5))
                        .overlay(
                            Image(systemName: s.isRest ? "xmark" : "checkmark")
                                .font(.ui(15, weight: .semibold))
                                .foregroundStyle(s.isRest ? Color.textMuted : .white)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.isRest ? "Rest day" : "Logged").font(.ui(14.5, weight: .bold)).foregroundStyle(Color.textPrimary)
                        if s.summary != (s.isRest ? "Rest day" : "Logged") {
                            Text(s.summary).font(.ui(12.5)).foregroundStyle(Color.textSoft)
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
                    Image(systemName: "pencil").font(.ui(13, weight: .semibold))
                    Text("Edit check-in").font(.ui(14, weight: .semibold))
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
                    Text(title).font(.ui(13.5, weight: .bold)).foregroundStyle(fg)
                    Text(subtitle).font(.ui(12)).foregroundStyle(Color.textSoft)
                }
                Spacer()
                Image(systemName: "arrow.right").font(.ui(14)).foregroundStyle(iconColor)
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
                .font(.ui(14.5, weight: .semibold))
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
                .font(.ui(13, weight: .semibold))
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
                        .font(.ui(11, weight: .bold))
                }
                Text(label).font(.ui(13.5, weight: .semibold))
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
            Text(label).font(.ui(11, weight: .semibold)).foregroundStyle(Color.textMuted)
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

    /// The streak, month count and goal describe HOW YOU ARE DOING — they are
    /// anchored to today, not to whichever day the check-in form happens to be
    /// editing. Progress is the launch screen now, and selectedDate defaults to
    /// yesterday (the day you usually still owe a check-in for), so reading the
    /// cursor showed last month's numbers every 1st and a stale streak daily.
    private var progressAnchor: Date { realToday }

    /// Every distinct day this month with either a check-in or logged activity.
    private var monthDaysCount: Int {
        let cal = Calendar.current
        var days = Set<Date>()
        for c in checkins where cal.isDate(c.date, equalTo: progressAnchor, toGranularity: .month) {
            days.insert(cal.startOfDay(for: c.date))
        }
        for w in allWorkouts where cal.isDate(w.date, equalTo: progressAnchor, toGranularity: .month) {
            days.insert(cal.startOfDay(for: w.date))
        }
        for s in allStretchLogs where cal.isDate(s.date, equalTo: progressAnchor, toGranularity: .month) {
            days.insert(cal.startOfDay(for: s.date))
        }
        return days.filter { mergedStatus(for: $0)?.qualifies == true }.count
    }

    private var progressPct: Double {
        min(1.0, Double(monthDaysCount) / Double(monthlyGoal))
    }

    /// Consecutive qualifying days ending today — or ending yesterday when
    /// today hasn't been logged yet, so an unlogged morning doesn't read as a
    /// broken streak. A logged workout alone keeps a day alive; no check-in
    /// tap needed.
    private var streak: Int {
        CheckInAutoFill.streak(endingAt: progressAnchor) { mergedStatus(for: $0) }
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
                    Text("of \(monthlyGoal) days").font(.ui(11, weight: .semibold)).foregroundStyle(Color.textMuted)
                }
            }

            Text(progressAnchor.formatted(.dateTime.month(.wide).year())).font(.heading(16)).foregroundStyle(Color.textPrimary)

            Text(monthDaysCount >= monthlyGoal
                 ? "Goal reached this month"
                 : "\(monthlyGoal - monthDaysCount) more workout day\(monthlyGoal - monthDaysCount == 1 ? "" : "s") to hit your goal")
                .font(.ui(13)).foregroundStyle(Color.textSoft).multilineTextAlignment(.center)

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
            Text(label).font(.ui(10.5, weight: .semibold)).foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    // MARK: History tab

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
            tabButton(.home, "chart.line.uptrend.xyaxis", "Progress")
            tabButton(.planner, "calendar", "Planner")
            tabButton(.tasks, "checklist", "Tasks")
            tabButton(.fitness, "figure.strengthtraining.traditional", "Fitness")
            tabButton(.library, "books.vertical.fill", "Library")
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
    }

    private func tabButton(_ target: Tab, _ icon: String, _ label: String) -> some View {
        Button { tab = target } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.ui(17))
                    .foregroundStyle(tab == target ? Color.accent : Color.textMuted)
                Text(label).font(.ui(10.5, weight: tab == target ? .bold : .medium))
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
