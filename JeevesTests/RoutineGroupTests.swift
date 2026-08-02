//
//  RoutineGroupTests.swift
//  JeevesTests
//
//  Interview prep and the gym as parents with independently switchable,
//  independently timed children — plus the migration that gets an existing
//  routine there without losing anything.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class RoutineGroupTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() {
        super.setUp()
        let schema = Schema([RoutineActivity.self, AppEvent.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try! ModelContainer(for: schema, configurations: [config])
    }
    override func tearDown() { container = nil; super.tearDown() }

    private func rows() -> [RoutineActivity] {
        ((try? context.fetch(FetchDescriptor<RoutineActivity>())) ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: migration

    func testPracticeRowBecomesFourIndependentCategories() {
        context.insert(RoutineActivity(name: "Interview prep — practice", durationMinutes: 100,
                                       tier: .important, sortOrder: 4))
        try? context.save()
        Baseline.regroup(in: context)

        let children = rows().filter { $0.group == .interviewPrep }
        XCTAssertEqual(Set(children.compactMap(\.prepCategory)),
                       Set(Baseline.practiceCategories),
                       "one row per question category")
        XCTAssertTrue(rows().allSatisfy { !$0.name.localizedCaseInsensitiveContains("practice") },
                      "the single practice row is replaced, not left beside its children")
        // 100 split four ways, floored at a usable 15.
        XCTAssertEqual(children.first?.durationMinutes, 25)
        XCTAssertTrue(children.allSatisfy { $0.tier == .important }, "the tier carries over")
    }

    func testPrepReadingJoinsTheParentAsItsOwnCategory() {
        context.insert(RoutineActivity(name: "Interview prep — Reading", durationMinutes: 90,
                                       tier: .mustDo, sortOrder: 1))
        try? context.save()
        Baseline.regroup(in: context)

        let reading = rows().first { $0.prepCategory == .reading }
        XCTAssertEqual(reading?.group, .interviewPrep)
        XCTAssertEqual(reading?.durationMinutes, 90, "it keeps its own length — it is not practice")
        XCTAssertEqual(reading?.tier, .mustDo)
    }

    func testGymArrivesAsThreeParts() {
        context.insert(RoutineActivity(name: "Chores", durationMinutes: 60, tier: .flexible, sortOrder: 0))
        try? context.save()
        Baseline.regroup(in: context)

        let gym = rows().filter { $0.group == .gym }
        XCTAssertEqual(gym.map(\.name), ["Mobility", "Weightlifting", "Cardio"])
        XCTAssertEqual(gym.map(\.durationMinutes), [20, 70, 35], "the historical session, now editable")
    }

    func testRegroupIsIdempotent() {
        context.insert(RoutineActivity(name: "Interview prep — practice", durationMinutes: 100,
                                       tier: .important, sortOrder: 0))
        try? context.save()
        Baseline.regroup(in: context)
        let after = rows().count
        Baseline.regroup(in: context)
        Baseline.regroup(in: context)
        XCTAssertEqual(rows().count, after, "running it again must not duplicate anything")
    }

    func testRegroupOnAnEmptyStoreDoesNothing() {
        Baseline.regroup(in: context)
        XCTAssertTrue(rows().isEmpty, "nothing to migrate, nothing invented")
    }

    // MARK: what the planner sees

    func testChildrenCarryTheirParentInThePlannerName() {
        let a = RoutineActivity(name: "Product Sense", durationMinutes: 25, tier: .important,
                                sortOrder: 0, group: .interviewPrep, prepCategory: .productSense)
        XCTAssertEqual(a.plannerName, "Interview prep — Product Sense",
                       "a bare 'Product Sense' block is unclassifiable downstream")
        let plain = RoutineActivity(name: "Chores", durationMinutes: 60, tier: .flexible, sortOrder: 1)
        XCTAssertEqual(plain.plannerName, "Chores")
    }

    func testGymChildrenAreNotFilledLikeRoutineActivities() {
        context.insert(RoutineActivity(name: "Chores", durationMinutes: 60, tier: .flexible, sortOrder: 0))
        context.insert(RoutineActivity(name: "Mobility", durationMinutes: 20, tier: .mustDo,
                                       sortOrder: 1, group: .gym))
        try? context.save()
        let routine = Baseline.routine(from: rows())
        XCTAssertFalse(routine.contains { $0.name.localizedCaseInsensitiveContains("mobility") },
                       "the gym is placed as an anchor, not poured into a gap")
    }

    func testDisabledGymPartsDropOutOfTheSession() {
        for (i, part) in Baseline.gymParts.enumerated() {
            context.insert(RoutineActivity(name: part.name, durationMinutes: part.minutes,
                                           tier: .mustDo, enabled: part.name != "Cardio",
                                           sortOrder: i, group: .gym))
        }
        try? context.save()
        let session = Baseline.gymSession(from: rows())
        XCTAssertEqual(session.map(\.name), ["Mobility", "Weightlifting"])
        XCTAssertEqual(session.map(\.minutes), [20, 70])
    }

    func testGymSessionFallsBackWhenNothingIsStored() {
        XCTAssertEqual(Baseline.gymSession(from: []).map(\.name), ["Mobility", "Weightlifting", "Cardio"])
    }
}
