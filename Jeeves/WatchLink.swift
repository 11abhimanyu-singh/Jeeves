//
//  WatchLink.swift
//  Jeeves
//
//  The iPhone half of the Watch bridge, now a shared singleton (WCSession has
//  exactly one delegate, and both the run screen and the lift logger need it).
//  Three jobs:
//    1. Send start/stop commands to the Watch (phone-driven workouts).
//    2. Receive the live BPM stream for on-screen heart rate.
//    3. The workout inbox — when a Watch workout starts, an in-progress
//       Workout card appears on Today; when it ends, the guaranteed-delivery
//       summary (duration + avg HR) finalizes it, even if the phone was in a
//       bag the whole time.
//

import Foundation
import Combine
import SwiftData
import WatchConnectivity

@MainActor
final class WatchLink: NSObject, ObservableObject {
    static let shared = WatchLink()

    /// Latest BPM streamed from the Watch, or nil if none yet.
    @Published var currentBPM: Int?
    /// Whether the Watch app is currently reachable for live messaging.
    @Published var reachable = false

    /// Set once at app launch; the inbox writes Workouts through this.
    private var container: ModelContainer?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func configure(container: ModelContainer) {
        self.container = container
    }

    /// Ask the Watch to begin a workout of the given kind (starts its HR
    /// streaming). Activity codes: "run", "strength", "walkIndoor",
    /// "walkOutdoor" — the Watch maps these to the right HKWorkoutActivityType.
    func startWorkout(activity: String = "run") { send(["cmd": "start", "activity": activity]) }

    /// Ask the Watch to end the workout, and clear the reading.
    func stopWorkout() {
        send(["cmd": "stop"])
        currentBPM = nil
    }

    private func send(_ message: [String: Any]) {
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else { return }
        s.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    // MARK: - Workout inbox

    /// A Watch workout just started: surface an in-progress card on Today
    /// (unless one of this type is already live).
    private func workoutStarted(activity: String) {
        guard let context = container?.mainContext else { return }
        let type = WorkoutType.from(activity: activity)
        guard matchToday(context, type: type, day: Date()) == nil else { return }
        context.insert(Workout(date: Date(), type: type, state: .live, source: .watch,
                               title: WorkoutType.title(forActivity: activity)))
        context.saveOrLog("WatchLink.workoutStarted")
    }

    /// The Watch's end-of-workout summary: finalize the live card if there is
    /// one, enrich a workout the phone already filed (a run saved by the run
    /// tool), or create the finished workout outright.
    private func workoutEnded(activity: String, startEpoch: Double, durationMin: Int, avgBPM: Int) {
        guard let context = container?.mainContext else { return }
        let type = WorkoutType.from(activity: activity)
        let start = startEpoch > 0 ? Date(timeIntervalSince1970: startEpoch) : Date()

        if let w = matchToday(context, type: type, day: start) {
            if w.durationMin == 0 { w.durationMin = durationMin }
            if w.avgBPM == 0, avgBPM > 0 { w.avgBPM = avgBPM }
            if w.state == .live {
                w.date = start
                // A run needs nothing more from the user; lifts and walks wait
                // for their sets / incline.
                w.state = (type == .run) ? .done : .needsDetail
            }
        } else {
            context.insert(Workout(date: start, type: type,
                                   state: (type == .run) ? .done : .needsDetail,
                                   source: .watch,
                                   title: WorkoutType.title(forActivity: activity),
                                   durationMin: durationMin, avgBPM: avgBPM))
        }
        context.saveOrLog("WatchLink.workoutEnded")
    }

    /// Today's workout this summary belongs to: a live one of the same type
    /// first; failing that, one the watch/phone already created for the same
    /// day that still lacks device data (or, for runs, the day's run — the run
    /// tool files it before the watch summary arrives).
    private func matchToday(_ context: ModelContext, type: WorkoutType, day: Date) -> Workout? {
        let cal = Calendar.current
        let all = ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .filter { $0.type == type && cal.isDate($0.date, inSameDayAs: day) }
        return all.first { $0.state == .live }
            ?? all.first { $0.durationMin == 0 && $0.source != .manual }
            ?? (type == .run ? all.max { $0.date < $1.date } : nil)
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.reachable = session.isReachable }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // reactivate for a newly-paired Watch
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.reachable = session.isReachable }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Extract plain values here (the payload itself isn't Sendable).
        if let bpm = message["bpm"] as? Int {
            Task { @MainActor in self.currentBPM = bpm }
        }
        if message["event"] as? String == "workoutStarted" {
            let activity = message["activity"] as? String ?? "run"
            Task { @MainActor in self.workoutStarted(activity: activity) }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo["event"] as? String == "workoutEnded" else { return }
        let activity = userInfo["activity"] as? String ?? "run"
        let startEpoch = userInfo["startEpoch"] as? Double ?? 0
        let durationMin = userInfo["durationMin"] as? Int ?? 0
        let avgBPM = userInfo["avgBPM"] as? Int ?? 0
        Task { @MainActor in
            self.workoutEnded(activity: activity, startEpoch: startEpoch,
                              durationMin: durationMin, avgBPM: avgBPM)
        }
    }
}
