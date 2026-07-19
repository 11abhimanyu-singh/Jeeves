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
    static let textMuted = Color(hex: "A19786")
    static let accent = Color(hex: "C67139")
    static let accentDeep = Color(hex: "8C491A")
    static let sage = Color(hex: "7A8A5E")
    static let sageDeep = Color(hex: "56633F")
    static let sageLight = Color(hex: "E1EECC")
}

// Stand-in for Caprasimo until the real font file is added to the project.
// .rounded gives a similarly friendly, bold display feel from system fonts.
extension Font {
    static func heading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
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
    @Query(sort: \CheckIn.date, order: .reverse) private var checkins: [CheckIn]

    enum Tab { case jeeves, planner, checkin, library, progress, history }

    @State private var tab: Tab = .planner
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

    private var realYesterday: Date { Date().addingTimeInterval(-86400).startOfDay }
    private var realToday: Date { Date().startOfDay }

    private func entry(for date: Date) -> CheckIn? {
        checkins.first { $0.date == date.startOfDay }
    }

    private var yesterdayDone: Bool { entry(for: realYesterday) != nil }
    private var todayDone: Bool { entry(for: realToday) != nil }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .jeeves: JeevesChatView()
                case .planner: DayPlannerView()
                case .checkin: checkinTab
                case .library: LibraryView()
                case .progress: progressTab
                case .history: historyTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider().overlay(Color.textPrimary.opacity(0.14))
            tabBar
        }
        .background(Color.bg)
        .onAppear { loadFields(for: selectedDate) }
        .onChange(of: selectedDate) { _, newDate in loadFields(for: newDate) }
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

    private var checkinTab: some View {
        VStack(spacing: 0) {
            moduleHeader("Check-in", "flame.fill") {
                if streak > 0 { streakChip }
            }
            Divider().overlay(Color.textPrimary.opacity(0.14))
            ScrollView {
                checkinView.padding(20)
            }
        }
    }

    private var progressTab: some View {
        VStack(spacing: 0) {
            moduleHeader("Progress", "chart.bar.fill") {
                if streak > 0 { streakChip }
            }
            Divider().overlay(Color.textPrimary.opacity(0.14))
            ScrollView {
                progressView.padding(20)
            }
        }
    }

    private var historyTab: some View {
        VStack(spacing: 0) {
            moduleHeader("History", "clock.fill") { EmptyView() }
            Divider().overlay(Color.textPrimary.opacity(0.14))
            historyView
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
                Text("Did you work out?").font(.heading(17)).foregroundStyle(Color.textPrimary).padding(.bottom, 14)

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
                        chip("Weight training", $weightTraining)
                        chip("Stretching", $stretching)
                        chip("Mobility", $mobility)
                        chip("Cardio", $cardio)
                    }
                    .padding(.bottom, cardio ? 16 : 4)

                    if cardio {
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

            if let e = entry(for: selectedDate) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(e.workedOut ? Color.sage : Color.bg)
                        .frame(width: 40, height: 40)
                        .overlay(Circle().stroke(e.workedOut ? .clear : Color.textPrimary.opacity(0.14), lineWidth: 1.5))
                        .overlay(
                            Image(systemName: e.workedOut ? "checkmark" : "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(e.workedOut ? .white : Color.textMuted)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.workedOut ? "Logged" : "Rest day").font(.system(size: 14.5, weight: .bold)).foregroundStyle(Color.textPrimary)
                        if e.workedOut {
                            Text(summary(for: e)).font(.system(size: 12.5)).foregroundStyle(Color.textSoft)
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

    private func chip(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                if isOn.wrappedValue {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                }
                Text(label).font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(isOn.wrappedValue ? .white : Color.textPrimary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(
                Capsule().fill(isOn.wrappedValue ? Color.sage : .clear)
                    .overlay(Capsule().stroke(isOn.wrappedValue ? .clear : Color.textPrimary.opacity(0.14), lineWidth: 1.5))
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

    private var monthDaysCount: Int {
        let cal = Calendar.current
        return checkins.filter {
            $0.workedOut &&
            cal.isDate($0.date, equalTo: selectedDate, toGranularity: .month)
        }.count
    }

    private var progressPct: Double {
        min(1.0, Double(monthDaysCount) / Double(monthlyGoal))
    }

    private var streak: Int {
        var count = 0
        var cursor = selectedDate
        let cal = Calendar.current
        while let e = entry(for: cursor), e.workedOut {
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

    private var historyView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if checkins.isEmpty {
                    Text("No check-ins yet").font(.system(size: 13.5)).foregroundStyle(Color.textMuted)
                        .padding(.vertical, 32)
                }
                historyRows
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var historyRows: some View {
                ForEach(checkins) { e in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(e.workedOut ? Color.sage : Color.bg)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Circle().stroke(e.workedOut ? .clear : Color.textPrimary.opacity(0.14), lineWidth: 1.5)
                            )
                            .overlay(
                                Image(systemName: e.workedOut ? "checkmark" : "xmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(e.workedOut ? .white : Color.textMuted)
                            )
                        VStack(alignment: .leading, spacing: 0) {
                            Text(prettyDate(e.date)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.textPrimary)
                            Text(summary(for: e)).font(.system(size: 12)).foregroundStyle(Color.textSoft).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
        }
    }

    private func summary(for e: CheckIn) -> String {
        guard e.workedOut else { return "Rest day" }
        var parts: [String] = []
        if e.weightTraining { parts.append("Weight") }
        if e.stretching { parts.append("Stretch") }
        if e.mobility { parts.append("Mobility") }
        if e.cardio {
            var c = "Cardio"
            if let t = e.cardioType {
                c += " (\(t == "Running" ? "Run" : "Walk")"
                if let d = e.cardioDuration { c += ", \(Int(d))min" }
                if let i = e.cardioIncline { c += ", \(formatNumber(i))%" }
                c += ")"
            }
            parts.append(c)
        }
        return parts.isEmpty ? "No details" : parts.joined(separator: " · ")
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.jeeves, "sparkles", "Jeeves")
            tabButton(.planner, "calendar", "Planner")
            tabButton(.checkin, "flame.fill", "Check-in")
            tabButton(.library, "books.vertical.fill", "Library")
            tabButton(.progress, "chart.bar.fill", "Progress")
            tabButton(.history, "clock.fill", "History")
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
        try? modelContext.save()
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
