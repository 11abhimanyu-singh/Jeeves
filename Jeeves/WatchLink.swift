//
//  WatchLink.swift
//  Jeeves
//
//  The iPhone half of the Watch heart-rate bridge. Sends start/stop to the Watch
//  companion when a run begins/ends and receives the live BPM it streams back,
//  so the run screen can show a continuous, low-latency heart rate (the Watch's
//  workout session is what keeps its sensor sampling). Best-effort: if the Watch
//  app isn't reachable, currentBPM stays nil and the HealthKit reader still
//  provides whatever samples land.
//

import Foundation
import Combine
import WatchConnectivity

@MainActor
final class WatchLink: NSObject, ObservableObject {
    /// Latest BPM streamed from the Watch, or nil if none yet.
    @Published var currentBPM: Int?
    /// Whether the Watch app is currently reachable for live messaging.
    @Published var reachable = false

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Ask the Watch to begin a run workout (starts its HR streaming).
    func startWorkout() { send(["cmd": "start"]) }

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
        guard let bpm = message["bpm"] as? Int else { return }
        Task { @MainActor in self.currentBPM = bpm }
    }
}
