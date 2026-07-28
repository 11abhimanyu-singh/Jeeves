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

    func start() {
        guard session == nil, HKHealthStore.isHealthDataAvailable() else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .indoor   // treadmill-friendly; fine outdoors too
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { _, _ in }
            isRunning = true
        } catch {
            session = nil; builder = nil
        }
    }

    func stop() {
        guard let session, let builder else { return }
        session.end()
        builder.endCollection(withEnd: Date()) { [weak self] _, _ in
            builder.finishWorkout { _, _ in }
            guard let self else { return }
            Task { @MainActor in
                self.session = nil
                self.builder = nil
                self.isRunning = false
                self.currentBPM = nil
            }
        }
    }

    /// Publish a new reading and forward it to the phone.
    private func publish(_ bpm: Int) {
        currentBPM = bpm
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
        Task { @MainActor in
            if cmd == "start" {
                await self.requestAuthorization()
                self.start()
            } else if cmd == "stop" {
                self.stop()
            }
        }
    }
}
