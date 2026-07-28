//
//  HealthKitService.swift
//  Jeeves
//
//  The heart-rate layer for the run screen. The Apple Watch (and AirPods Pro 3
//  during a workout) write heart-rate samples into HealthKit; this streams the
//  latest one to the live-run UI and computes the run's average when it's logged.
//
//  iOS-only by design: it surfaces whatever HealthKit is receiving, so live BPM
//  is low-latency while a Watch/AirPods workout is actively recording and sparser
//  otherwise. A watchOS companion that runs its own HKWorkoutSession (for
//  continuous streaming without another app driving it) is the later enhancement.
//
//  Best-effort throughout: if Health data is unavailable or permission is denied,
//  currentBPM stays nil and the run still logs — just without a heart rate.
//

import Foundation
import Combine
import HealthKit

@MainActor
final class HeartRateMonitor: ObservableObject {
    /// The most recent heart-rate reading, in BPM. Nil until a sample arrives.
    @Published var currentBPM: Int?

    private let store = HKHealthStore()
    private let hrType = HKQuantityType(.heartRate)
    private var liveQuery: HKAnchoredObjectQuery?

    /// count/min — HealthKit's unit for heart rate. Built locally where needed so
    /// it's never shared across the background query callbacks.
    nonisolated private static func bpmUnit() -> HKUnit { HKUnit.count().unitDivided(by: .minute()) }

    /// Request read access to heart rate. Safe to call repeatedly; no-op if
    /// Health data isn't available on this device.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: [], read: [hrType])
    }

    /// Start streaming new heart-rate samples (from now on) into `currentBPM`.
    func start() {
        guard HKHealthStore.isHealthDataAvailable(), liveQuery == nil else { return }
        let predicate = HKQuery.predicateForSamples(withStart: Date(), end: nil, options: .strictStartDate)
        let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            guard let self,
                  let latest = (samples as? [HKQuantitySample])?.max(by: { $0.endDate < $1.endDate }) else { return }
            let bpm = Int(latest.quantity.doubleValue(for: HeartRateMonitor.bpmUnit()).rounded())
            Task { @MainActor in self.currentBPM = bpm }
        }
        let query = HKAnchoredObjectQuery(type: hrType, predicate: predicate, anchor: nil,
                                          limit: HKObjectQueryNoLimit, resultsHandler: handler)
        query.updateHandler = handler
        liveQuery = query
        store.execute(query)
    }

    /// Stop the live stream and clear the reading.
    func stop() {
        if let query = liveQuery { store.stop(query) }
        liveQuery = nil
        currentBPM = nil
    }

    /// Average BPM across [start, end], for the logged RunSession. Nil if there
    /// were no samples (no Watch/AirPods HR during the run).
    func averageBPM(from start: Date, to end: Date) async -> Int? {
        guard HKHealthStore.isHealthDataAvailable(), end > start else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: hrType, quantitySamplePredicate: predicate,
                                          options: .discreteAverage) { _, stats, _ in
                let avg = stats?.averageQuantity()?.doubleValue(for: HeartRateMonitor.bpmUnit())
                continuation.resume(returning: avg.map { Int($0.rounded()) })
            }
            store.execute(query)
        }
    }
}
