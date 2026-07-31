//
//  TrajectoryTests.swift
//  JeevesTests
//
//  The autonomous Tier 1 runner: every dialogue in
//  tools/scenarios-chat/dialogues.json is played against the REAL model
//  (claude-sonnet-5, key injected via environment) and the REAL tool
//  executor, on an in-memory store — no human, no phone. After the whole
//  suite runs, deterministic invariants are asserted on the end state and a
//  full artifact (transcript + every tool call + end-state summary) is
//  exported for the story-vs-state judge.
//
//  Skips cleanly when ANTHROPIC_API_KEY is absent, so the normal unit-test
//  run never needs the network. Launch via tools/run-trajectories.sh.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class TrajectoryTests: XCTestCase {

    private var container: ModelContainer!

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private struct Dialogue: Decodable {
        let id: String
        let turns: [String]
        let expect: String
    }
    private struct PlanFile: Decodable { let tier1: [Dialogue] }

    private struct RecordedCall: Codable {
        let dialogue: String
        let name: String
        let input: String
        let result: String
    }
    private struct RecordedTurn: Codable {
        let dialogue: String
        let role: String
        let text: String
    }

    func testTier1DialoguesEndToEnd() async throws {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            throw XCTSkip("No ANTHROPIC_API_KEY in environment — run via tools/run-trajectories.sh")
        }

        // The app's full schema: tools touch most of it.
        let schema = Schema([
            CheckIn.self, JobApplication.self, PrepSession.self, LeisureLog.self,
            DailyPlanState.self, Book.self, ReadingLog.self, SavedLocation.self,
            DailyEvent.self, ChatTurn.self, RoutineActivity.self, PlanGenerationLog.self,
            LiftSession.self, LiftSet.self, RunSession.self, StretchLog.self,
            Reminder.self, Todo.self, Workout.self, VoiceNote.self,
            Trip.self, TravelSegment.self, TripStay.self, AppEvent.self,
            CalendarTombstone.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        // A saved Home so tools that resolve "Home" behave like the real app.
        context.insert(SavedLocation(kind: .home, address: "Indiranagar, Bengaluru"))
        try? context.save()

        let executor = ChatToolExecutor(modelContext: context)
        // Live traffic can't be measured from an in-memory suite — a fixed
        // stub keeps journeys honest (non-zero) without the network. And no
        // notification scheduling: a fresh simulator's permission prompt
        // would hang a headless run.
        executor.commuteMinutes = { _, _, _ in 45 }
        executor.scheduleNudges = false

        // Load the permanent dialogue plan from the repo.
        let planURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/scenarios-chat/dialogues.json")
        let plan = try JSONDecoder().decode(PlanFile.self, from: Data(contentsOf: planURL))

        var transcript: [RecordedTurn] = []
        var calls: [RecordedCall] = []
        var history: [ChatMessage] = []
        var failures: [String] = []

        for dialogue in plan.tier1 {
            for turn in dialogue.turns {
                transcript.append(RecordedTurn(dialogue: dialogue.id, role: "user", text: turn))
                do {
                    let reply = try await JeevesChatService.sendAgentic(
                        history: history, newMessage: turn,
                        stateNote: executor.stateNote(),
                        execute: { call in
                            let result = await executor.run(call)
                            calls.append(RecordedCall(
                                dialogue: dialogue.id, name: call.name,
                                input: String(describing: call.input).prefix(400).description,
                                result: String(result.text.prefix(400))))
                            return result
                        })
                    history.append(ChatMessage(role: .user, content: turn))
                    if !reply.text.isEmpty {
                        history.append(ChatMessage(role: .assistant, content: reply.text))
                        transcript.append(RecordedTurn(dialogue: dialogue.id, role: "assistant",
                                                       text: reply.text))
                    }
                } catch {
                    failures.append("\(dialogue.id): turn '\(turn.prefix(40))' errored: \(error.localizedDescription)")
                    transcript.append(RecordedTurn(dialogue: dialogue.id, role: "error",
                                                   text: error.localizedDescription))
                }
            }
        }

        // ---- Deterministic end-state invariants (the story-independent floor) ----
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        let segments = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        let events = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []

        // No two trips with identical title AND overlapping dates.
        for i in trips.indices {
            for j in trips.indices where j > i {
                let a = trips[i], b = trips[j]
                if a.title.compare(b.title, options: .caseInsensitive) == .orderedSame,
                   a.endDate >= b.startDate, b.endDate >= a.startDate {
                    failures.append("duplicate trips: '\(a.title)' twice over the same dates")
                }
            }
        }
        // No two journeys of the same mode on the same day within one trip
        // heading to the same place.
        for i in segments.indices {
            for j in segments.indices where j > i {
                let a = segments[i], b = segments[j]
                if a.tripID == b.tripID, a.mode == b.mode, a.toPlace == b.toPlace,
                   Calendar.current.isDate(a.day, inSameDayAs: b.day) {
                    failures.append("duplicate journeys: '\(a.label)' twice on the same day")
                }
            }
        }
        // No duplicate stays (same trip, place, overlapping dates).
        for i in stays.indices {
            for j in stays.indices where j > i {
                let a = stays[i], b = stays[j]
                if a.tripID == b.tripID, a.place == b.place,
                   a.departDate >= b.arriveDate, b.departDate >= a.arriveDate {
                    failures.append("duplicate stays: '\(a.place)' twice")
                }
            }
        }
        // No duplicate events (same title, same day).
        for i in events.indices {
            for j in events.indices where j > i {
                let a = events[i], b = events[j]
                if a.title.lowercased() == b.title.lowercased(),
                   Calendar.current.isDate(a.date, inSameDayAs: b.date) {
                    failures.append("duplicate events: '\(a.title)' twice on the same day")
                }
            }
        }

        // ---- Export the artifact for the story-vs-state judge ----
        let outDir = ProcessInfo.processInfo.environment["TRAJECTORY_OUT"]
            ?? "/tmp/jeeves-trajectories"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let artifact: [String: Any] = [
            "transcript": transcript.map { ["dialogue": $0.dialogue, "role": $0.role, "text": $0.text] },
            "toolCalls": calls.map { ["dialogue": $0.dialogue, "name": $0.name,
                                      "input": $0.input, "result": $0.result] },
            "endState": [
                "trips": trips.map { "\($0.title) \($0.startDate) → \($0.endDate)" },
                "stays": stays.map { "\($0.place) \($0.arriveDate) → \($0.departDate)" },
                "journeys": segments.map { "[\($0.mode.rawValue)] \($0.label) travel=\($0.travelMinutes)" },
                "events": events.map { "\($0.title) \($0.date) \($0.startMinute)-\($0.endMinute)" },
            ],
            "failures": failures,
            "expectations": plan.tier1.map { ["id": $0.id, "expect": $0.expect] },
        ]
        let data = try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
        let outPath = "\(outDir)/tier1-\(stamp).json"
        try data.write(to: URL(fileURLWithPath: outPath))
        print("TRAJECTORY ARTIFACT: \(outPath)")

        XCTAssertTrue(failures.isEmpty, "trajectory failures:\n" + failures.joined(separator: "\n"))
    }
}
