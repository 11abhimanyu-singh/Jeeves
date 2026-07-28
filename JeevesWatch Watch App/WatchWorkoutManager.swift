//
//  WatchWorkoutManager.swift
//  JeevesWatch Watch App
//
//  Runs an HKWorkoutSession on the Watch so its heart-rate sensor samples
//  continuously (the only way to get low-latency HR on watchOS), and streams
//  each reading to the iPhone over WatchConnectivity. The phone can also drive
//  it: a {cmd:"start"/"stop"} message begins/ends the session so a Jeeves run on
//  the phone auto-starts the Watch workout (when the Watch app is reachable).
//

import Foundation
import Combine
import HealthKit
import WatchConnectivity

@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    @Published var currentBPM: Int?
    @Published var isRunning = false

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    // Session summary the phone needs: what ran, since when, and the running
    // heart-rate average (sum/count of every published sample).
    private var activity = "run"
    private var startDate: Date?
    private var hrSum = 0
    private var hrCount = 0

    nonisolated static func bpmUnit() -> HKUnit { HKUnit.count().unitDivided(by: .minute()) }

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Ask for the write (workout) + read (heart rate) access a live workout needs.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
        try? await store.requestAuthorization(toShare: share, read: read)
    }

    /// Maps our activity codes to a HealthKit workout configuration so each
    /// session is categorised correctly in Health (and the rings).
    private func configuration(for activity: String) -> HKWorkoutConfiguration {
        let config = HKWorkoutConfiguration()
        switch activity {
        case "strength":
            config.activityType = .traditionalStrengthTraining
            config.locationType = .indoor
        case "walkIndoor":
            config.activityType = .walking
            config.locationType = .indoor
        case "walkOutdoor":
            config.activityType = .walking
            config.locationType = .outdoor
        default:                                   // "run" — unchanged
            config.activityType = .running
            config.locationType = .indoor
        }
        return config
    }

    func start(activity: String = "run") {
        guard session == nil, HKHealthStore.isHealthDataAvailable() else { return }
        let config = configuration(for: activity)
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            let startDate = Date()
            self.activity = activity
            self.startDate = startDate
            self.hrSum = 0
            self.hrCount = 0
            session.startActivity(with: startDate)
            isRunning = true   // optimistic so the UI responds; reverted if collection can't begin
            builder.beginCollection(withStart: startDate) { [weak self] began, _ in
                guard !began else { return }
                Task { @MainActor in
                    self?.session = nil; self?.builder = nil; self?.isRunning = false
                }
            }
            // Best-effort heads-up so the phone can show an in-progress card.
            let s = WCSession.default
            if s.activationState == .activated, s.isReachable {
                s.sendMessage(["event": "workoutStarted", "activity": activity],
                              replyHandler: nil, errorHandler: nil)
            }
        } catch {
            session = nil; builder = nil
        }
    }

    func stop() {
        guard let session, let builder else { return }
        sendSummary()
        session.end()
        builder.endCollection(withEnd: Date()) { [weak self] _, _ in
            // Reset only AFTER the workout is finalized (and saved), not before,
            // so the UI doesn't show "stopped" while HealthKit is still writing.
            builder.finishWorkout { _, _ in
                Task { @MainActor in
                    self?.session = nil
                    self?.builder = nil
                    self?.isRunning = false
                    self?.currentBPM = nil
                    self?.startDate = nil
                }
            }
        }
    }

    /// Hands the finished session to the phone via the guaranteed-delivery
    /// queue, so the workout lands on the Today feed even if the phone is in a
    /// bag right now. Sub-minute sessions are dropped — they're almost always
    /// an accidental start.
    private func sendSummary() {
        guard let startDate else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        guard elapsed >= 60 else { return }
        let avg = hrCount > 0 ? hrSum / hrCount : 0
        WCSession.default.transferUserInfo([
            "event": "workoutEnded",
            "activity": activity,
            "startEpoch": startDate.timeIntervalSince1970,
            "durationMin": Int((elapsed / 60).rounded()),
            "avgBPM": avg,
        ])
    }

    /// Publish a new reading and forward it to the phone.
    private func publish(_ bpm: Int) {
        currentBPM = bpm
        hrSum += bpm
        hrCount += 1
        let s = WCSession.default
        if s.activationState == .activated, s.isReachable {
            s.sendMessage(["bpm": bpm], replyHandler: nil, errorHandler: nil)
        }
    }
}

// MARK: - Workout session lifecycle

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        Task { @MainActor in self.session = nil; self.builder = nil; self.isRunning = false }
    }
}

// MARK: - Live data (heart rate)

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(HKQuantityType(.heartRate)),
              let stats = workoutBuilder.statistics(for: HKQuantityType(.heartRate)),
              let bpm = stats.mostRecentQuantity()?.doubleValue(for: WatchWorkoutManager.bpmUnit())
        else { return }
        let value = Int(bpm.rounded())
        Task { @MainActor in self.publish(value) }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - Phone commands

extension WatchWorkoutManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let cmd = message["cmd"] as? String else { return }
        let activity = message["activity"] as? String ?? "run"
        Task { @MainActor in
            if cmd == "start" {
                await self.requestAuthorization()
                self.start(activity: activity)
            } else if cmd == "stop" {
                self.stop()
            }
        }
    }
}
