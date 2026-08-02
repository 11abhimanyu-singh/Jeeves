//
//  TicketImportView.swift
//  Jeeves
//
//  Pick a ticket, see exactly what it would do, then say yes.
//
//  Nothing here writes until `apply()`, and `apply()` only runs from a button
//  the user pressed while looking at the plan. That is the same contract as
//  the calendar review sheet, and it exists because the two easy behaviours —
//  create a second overlapping trip, or silently overwrite the one you have —
//  are both wrong and both invisible until the damage is done.
//

import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct TicketImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var trips: [Trip]
    @Query private var allStays: [TripStay]

    private enum Phase: Equatable {
        case choosing
        case reading
        case review(TicketImportPlan, [ItineraryProblem])
        case failed(String)
        case done(String)
    }

    @State private var phase: Phase = .choosing
    @State private var showPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var removeRedundant = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch phase {
                    case .choosing:                 chooser
                    case .reading:                  reading
                    case .review(let plan, let ps): review(plan, ps)
                    case .failed(let message):      failure(message)
                    case .done(let receipt):        finished(receipt)
                    }
                }
                .padding(18)
            }
            .background(Color.bg)
            .navigationTitle("Import a ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.tint(Color.accentDeep)
                }
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.pdf, .image],
                          allowsMultipleSelection: false) { result in
                handle(result)
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                phase = .reading
                Task {
                    defer { photoItem = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        phase = .failed("Couldn't load that image.")
                        return
                    }
                    await extractImage(image)
                }
            }
        }
    }

    // MARK: Phases

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drop in a flight ticket")
                .font(.serif(20)).foregroundStyle(Color.textPrimary)
            Text("I'll read the legs, work out which gaps are stays and which are just connections, and show you the trip before anything is saved.")
                .font(.ui(13)).foregroundStyle(Color.textSoft)
                .fixedSize(horizontal: false, vertical: true)

            Button { showPicker = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                    Text("Choose a file").font(.ui(15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose a ticket PDF or image")

            // Most tickets arrive as a screenshot, not a file.
            PhotosPicker(selection: $photoItem, matching: .images) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                    Text("Choose a photo or screenshot").font(.ui(15, weight: .semibold))
                }
                .foregroundStyle(Color.accentDeep)
                .frame(maxWidth: .infinity).frame(minHeight: 44).padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentDeep.opacity(0.45), lineWidth: 1.3))
            }
            .accessibilityLabel("Choose a ticket photo")

            Text("PDF, photo or screenshot. A PDF with real text is read directly — anything else is looked at, which is slower and less certain.")
                .font(.ui(11)).foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reading: some View {
        HStack(spacing: 9) {
            ProgressView()
            Text("Reading the ticket…").font(.ui(13)).foregroundStyle(Color.textSoft)
        }
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func review(_ plan: TicketImportPlan, _ problems: [ItineraryProblem]) -> some View {
        // Legs
        eyebrow("\(plan.journeys.count) legs")
        VStack(spacing: 0) {
            ForEach(Array(plan.journeys.enumerated()), id: \.offset) { index, leg in
                legRow(leg)
                if index < plan.journeys.count - 1 {
                    Divider().overlay(Color.textPrimary.opacity(0.10))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))

        // Shape
        VStack(alignment: .leading, spacing: 5) {
            shapeRow("Trip", plan.tripTitle)
            shapeRow("Dates", "\(dayLabel(plan.tripStart)) – \(dayLabel(plan.tripEnd)) · \(plan.dayCount) days")
            ForEach(Array(plan.stays.enumerated()), id: \.offset) { _, stay in
                shapeRow(stay.place, "\(dayLabel(stay.arriveDate)) – \(dayLabel(stay.departDate))")
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.travelBg))

        // Anything worth knowing that isn't fatal
        ForEach(Array(problems.filter { !$0.isFatal }.enumerated()), id: \.offset) { _, problem in
            warning(problem.message)
        }

        // Collision
        if case .updateTrip(let title, _, _) = plan.action {
            VStack(alignment: .leading, spacing: 6) {
                Text("A trip called “\(title)” already covers these days")
                    .font(.ui(12.5, weight: .bold)).foregroundStyle(Color.accentDeep)
                ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                    Text("• " + note).font(.ui(11.5)).foregroundStyle(Color.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("I'll update it rather than start a second one.")
                    .font(.ui(11.5)).foregroundStyle(Color.textSoft).padding(.top, 2)
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: "F6E2D2")))
        }

        if !plan.redundantStays.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("Leftover stays").font(.ui(12.5, weight: .bold)).foregroundStyle(Color.textPrimary)
                ForEach(Array(plan.redundantStays.enumerated()), id: \.offset) { _, stay in
                    Text("• \(stay.place) \(dayLabel(stay.arriveDate))–\(dayLabel(stay.departDate)) — \(stay.reason)")
                        .font(.ui(11.5)).foregroundStyle(Color.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $removeRedundant) {
                    Text("Remove them").font(.ui(12.5, weight: .semibold))
                }
                .tint(Color.accent)
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.surfaceDeep))
        }

        Button { apply(plan) } label: {
            Text(applyLabel(plan))
                .font(.ui(15, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accent))
        }
        .buttonStyle(.plain)

        Text("Nothing has been saved yet.")
            .font(.ui(11)).foregroundStyle(Color.textMuted)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("I couldn't import this")
                .font(.serif(18)).foregroundStyle(Color.textPrimary)
            Text(message).font(.ui(13)).foregroundStyle(Color.accentDeep)
                .fixedSize(horizontal: false, vertical: true)
            Button { phase = .choosing } label: {
                Text("Try another file").font(.ui(13, weight: .semibold))
                    .foregroundStyle(Color.accentDeep)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentDeep.opacity(0.45), lineWidth: 1.3))
            }
            .buttonStyle(.plain)
        }
    }

    private func finished(_ receipt: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Done").font(.serif(20)).foregroundStyle(Color.textPrimary)
            Text(receipt).font(.ui(13)).foregroundStyle(Color.textSoft)
                .fixedSize(horizontal: false, vertical: true)
            Button { dismiss() } label: {
                Text("Close").font(.ui(15, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.sageDeep))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Rows

    private func legRow(_ leg: PlannedJourney) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(leg.label).font(.serif(15)).foregroundStyle(Color.textPrimary)
            HStack(alignment: .top, spacing: 8) {
                endBlock(leg.fromPlace, terminal: leg.fromTerminal,
                         time: leg.departAt, zone: leg.fromTimeZoneID, align: .leading)
                Text("→").font(.ui(11)).foregroundStyle(Color.textMuted).padding(.top, 2)
                endBlock(leg.toPlace, terminal: leg.toTerminal,
                         time: leg.arriveAt, zone: leg.toTimeZoneID, align: .trailing)
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func endBlock(_ place: String, terminal: String?, time: Date,
                          zone: String, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 2) {
            Text(place).font(.ui(11)).foregroundStyle(Color.textMuted)
                .lineLimit(2).multilineTextAlignment(align == .leading ? .leading : .trailing)
            HStack(spacing: 4) {
                Text(clock(time, zone: zone)).font(.ui(14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary).monospacedDigit()
                Text(abbrev(zone)).font(.ui(9.5, weight: .semibold)).foregroundStyle(Color.textMuted)
            }
            Text(terminal.map { "Terminal \($0)" } ?? "Terminal —")
                .font(.ui(9.5, weight: .semibold))
                .foregroundStyle(terminal == nil ? Color.textMuted : Color.travelInk)
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }

    private func shapeRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.ui(12)).foregroundStyle(Color.textSoft)
            Spacer()
            Text(value).font(.ui(12, weight: .semibold)).foregroundStyle(Color.travelInk)
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased()).font(.ui(10, weight: .bold)).kerning(1)
            .foregroundStyle(Color.textMuted)
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.ui(11.5)).foregroundStyle(Color.accentDeep)
            .fixedSize(horizontal: false, vertical: true)
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "F6E2D2")))
    }

    // MARK: Work

    private func handle(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        phase = .reading
        Task {
            // Files picked outside the sandbox need the scope opened first.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                // A PDF gets the text path with an image fallback; anything
                // else picked here is an image already.
                let isPDF = url.pathExtension.lowercased() == "pdf"
                let extracted: (legs: [TicketLeg], booking: TicketBooking)
                if isPDF {
                    extracted = try await TicketExtractionService.extract(from: data)
                } else if let image = UIImage(data: data) {
                    extracted = try await TicketExtractionService.extract(fromImage: image)
                } else {
                    phase = .failed("Couldn't open that file.")
                    return
                }
                present(extracted)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func extractImage(_ image: UIImage) async {
        do {
            present(try await TicketExtractionService.extract(fromImage: image))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Shared tail: resolve, look for a collision, show the plan.
    private func present(_ extracted: (legs: [TicketLeg], booking: TicketBooking)) {
        let (itinerary, problems) = TicketItinerary.resolve(legs: extracted.legs,
                                                            booking: extracted.booking)
        guard let itinerary else {
            phase = .failed(problems.first?.message ?? "I couldn't read the flights.")
            return
        }
        let existing = overlappingTrip(start: itinerary.startUTC, end: itinerary.endUTC)
        guard let plan = TicketImportPlanner.plan(from: itinerary, existing: existing) else {
            phase = .failed("That ticket had no usable flights.")
            return
        }
        phase = .review(plan, problems)
    }

    /// The trip, if any, whose window overlaps the ticket's.
    private func overlappingTrip(start: Date?, end: Date?) -> ExistingTrip? {
        guard let start, let end else { return nil }
        let cal = Calendar.current
        guard let match = trips.first(where: { $0.startDate <= cal.startOfDay(for: end)
                                            && $0.endDate >= cal.startOfDay(for: start) }) else { return nil }
        return ExistingTrip(title: match.title,
                            startDate: match.startDate,
                            endDate: match.endDate,
                            stays: allStays.filter { $0.tripID == match.id }
                                .map { .init(place: $0.place,
                                             arriveDate: $0.arriveDate,
                                             departDate: $0.departDate) })
    }

    private func applyLabel(_ plan: TicketImportPlan) -> String {
        switch plan.action {
        case .createTrip:            return "Create \(plan.tripTitle)"
        case .updateTrip(let t, _, _): return "Update \(t)"
        }
    }

    /// The only place anything is written.
    private func apply(_ plan: TicketImportPlan) {
        let cal = Calendar.current
        let trip: Trip

        switch plan.action {
        case .createTrip:
            trip = Trip(title: plan.tripTitle, startDate: plan.tripStart, endDate: plan.tripEnd)
            modelContext.insert(trip)
        case .updateTrip(let title, _, _):
            guard let existing = trips.first(where: { $0.title == title }) else {
                phase = .failed("The trip I was going to update has gone.")
                return
            }
            trip = existing
            trip.title = plan.tripTitle
            trip.startDate = plan.tripStart
            trip.endDate = plan.tripEnd
        }

        var removed = 0
        if removeRedundant {
            for stay in allStays where stay.tripID == trip.id {
                if plan.redundantStays.contains(where: {
                    $0.place.caseInsensitiveCompare(stay.place) == .orderedSame
                    && cal.isDate($0.arriveDate, inSameDayAs: stay.arriveDate)
                    && cal.isDate($0.departDate, inSameDayAs: stay.departDate)
                }) {
                    modelContext.delete(stay)
                    removed += 1
                }
            }
        }

        // Stays: update one that already matches the place, else insert.
        for planned in plan.stays {
            if let existing = allStays.first(where: {
                $0.tripID == trip.id && $0.place.caseInsensitiveCompare(planned.place) == .orderedSame
            }) {
                existing.arriveDate = planned.arriveDate
                existing.departDate = planned.departDate
                existing.timeZoneID = planned.timeZoneID
            } else {
                modelContext.insert(TripStay(tripID: trip.id, place: planned.place,
                                             arriveDate: planned.arriveDate,
                                             departDate: planned.departDate))
            }
        }

        for journey in plan.journeys {
            let segment = TravelSegment(tripID: trip.id, mode: .flight, label: journey.label,
                                        fromPlace: journey.fromPlace, toPlace: journey.toPlace,
                                        departAt: journey.departAt, arriveBy: nil,
                                        arriveAt: journey.arriveAt,
                                        fromTimeZoneID: journey.fromTimeZoneID,
                                        toTimeZoneID: journey.toTimeZoneID,
                                        checkInMinutes: journey.checkInMinutes)
            modelContext.insert(segment)
        }

        modelContext.saveOrLog("TicketImport.apply")

        // A receipt that names exactly what changed, per the app's own rule.
        var parts = ["\(plan.journeys.count) journeys", "\(plan.stays.count) stays"]
        if removed > 0 { parts.append("\(removed) leftover stay\(removed == 1 ? "" : "s") removed") }
        phase = .done("\(plan.tripTitle), \(dayLabel(plan.tripStart))–\(dayLabel(plan.tripEnd)): "
                      + parts.joined(separator: ", ")
                      + ". Journey times aren't measured yet — open the trip to price the airport runs.")
    }

    // MARK: Formatting

    private func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func clock(_ date: Date, zone: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: zone) ?? .current
        return f.string(from: date)
    }

    /// "IST" / "SGT" — the label under a time, so two 06:10s can be told apart.
    private func abbrev(_ zoneID: String) -> String {
        guard let zone = TimeZone(identifier: zoneID) else { return "" }
        return zone.abbreviation() ?? ""
    }
}
