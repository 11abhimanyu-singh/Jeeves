//
//  BackgroundPlanSession.swift
//  Jeeves
//
//  A plan request that outlives the app being put down.
//
//  The device log says a successful generation takes ~53 seconds, and the
//  foreground assertion in BackgroundActivity buys roughly 30 — its own comment
//  says as much, and names the fix: "a minutes-long background would need a
//  background URLSession instead." So a tap followed by switching away kills the
//  request, and the day falls back to the offline scheduler. That is a third of
//  every plan built from the planner button.
//
//  A background URLSession is handed to the system: the transfer continues while
//  the app is suspended, and iOS relaunches the app to deliver the result if it
//  was terminated. Two consequences shape everything here:
//
//  1. Background sessions do NOT allow `httpBody` or `dataTask`. The request
//     body is written to a file and sent with `uploadTask(with:fromFile:)`.
//  2. The result can arrive when nobody is waiting for it. So the day being
//     planned rides along in `taskDescription`, which survives into the
//     relaunched process, and the completion path can commit a plan for a day
//     no live screen is looking at.
//
//  OFF BY DEFAULT. Suspension and relaunch cannot be exercised on a simulator,
//  so this ships dark: `isEnabled` gates it, the existing foreground path stays
//  the default, and it can be switched on for a soak test on a real phone
//  without putting the working path at risk.
//

import Foundation
import SwiftData

@MainActor
final class BackgroundPlanSession: NSObject {
    static let shared = BackgroundPlanSession()

    /// Must be stable across launches — iOS reattaches to the session by it.
    static let identifier = "abhimanyusingh.me.Jeeves.plan-generation"

    /// Ships dark. See the file comment: unverifiable without a real device
    /// soak, so it does not become the default on my say-so.
    static let enabledKey = "plan.backgroundSession.enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Set at launch so a relaunched process can commit a plan that arrives
    /// with no screen waiting for it.
    static var container: ModelContainer?

    /// Held for `urlSessionDidFinishEvents` — iOS wants it called once every
    /// delivered event has been handled, or it stops waking the app.
    var systemCompletionHandler: (() -> Void)?

    private var buffers: [Int: Data] = [:]
    private var waiters: [Int: CheckedContinuation<Data, Error>] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        // Wake the app when the transfer finishes, even after termination.
        config.sessionSendsLaunchEvents = true
        // A plan the user is waiting for is not discretionary work; letting iOS
        // defer it to a charging window would defeat the point.
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Reattach at launch so deliveries for a terminated run are received.
    static func activate(container: ModelContainer) {
        Self.container = container
        guard isEnabled else { return }
        _ = shared.session
    }

    // MARK: Sending

    /// What rides along with the task so a result arriving into a fresh process
    /// still knows what it was for.
    struct Ticket: Codable {
        let day: Date
        let trigger: String
    }

    /// Send a prepared request body, awaiting the response while the app is
    /// alive. If the app is suspended or killed mid-flight the transfer still
    /// completes; `onOrphanedResult` handles it on relaunch.
    func send(body: Data, to request: URLRequest, ticket: Ticket) async throws -> Data {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-\(UUID().uuidString).json")
        try body.write(to: file)

        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = (try? JSONEncoder().encode(ticket))
            .flatMap { String(data: $0, encoding: .utf8) }

        return try await withCheckedThrowingContinuation { continuation in
            waiters[task.taskIdentifier] = continuation
            task.resume()
        }
    }

    /// Called when a response arrives with nobody waiting — the app was killed
    /// and relaunched to receive it. Set by the app so this file does not have
    /// to know how a plan is committed.
    static var onOrphanedResult: ((Data, Ticket) -> Void)?

    // MARK: Delivery

    fileprivate func accumulate(_ data: Data, for id: Int) {
        buffers[id, default: Data()].append(data)
    }

    fileprivate func complete(id: Int, description: String?, error: Error?) {
        let data = buffers.removeValue(forKey: id) ?? Data()
        if let waiter = waiters.removeValue(forKey: id) {
            if let error { waiter.resume(throwing: error) }
            else { waiter.resume(returning: data) }
            return
        }
        // Nobody is waiting: this is a delivery into a relaunched process.
        // Dropping it silently would waste a plan the user already paid for.
        guard error == nil, !data.isEmpty,
              let raw = description?.data(using: .utf8),
              let ticket = try? JSONDecoder().decode(Ticket.self, from: raw)
        else { return }
        Self.onOrphanedResult?(data, ticket)
    }
}

// The delegate callbacks arrive on a background queue; every piece of state
// above is main-actor, so each hops before touching it.
extension BackgroundPlanSession: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive data: Data) {
        let id = dataTask.taskIdentifier
        Task { @MainActor in self.accumulate(data, for: id) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let description = task.taskDescription
        Task { @MainActor in self.complete(id: id, description: description, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.systemCompletionHandler?()
            self.systemCompletionHandler = nil
        }
    }
}
