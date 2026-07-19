//
//  ChatTurn.swift
//  Jeeves
//
//  A persisted line in the Jeeves conversation. The chat used to be in-memory
//  @State, which wiped on every tab switch; persisting it means the thread
//  survives navigation, backgrounding, and app restarts. Sessions are scoped
//  per day (`day` = startOfDay): the planner shows today's thread and starts
//  fresh each calendar day, with a manual "New chat" to clear early.
//

import Foundation
import SwiftData

@Model
final class ChatTurn {
    var id: UUID
    var timestamp: Date
    var day: Date            // startOfDay — session scoping
    var roleRaw: String      // "user" | "assistant"
    var content: String
    var planJSON: String?    // encoded GeneratedPlan when this turn is a plan
    var isOfflinePlan: Bool
    @Attribute(.externalStorage) var imageData: Data?  // uploaded ticket, shown in-thread

    init(
        role: String,
        content: String,
        day: Date,
        planJSON: String? = nil,
        isOfflinePlan: Bool = false,
        imageData: Data? = nil,
        timestamp: Date = .now
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.day = day
        self.roleRaw = role
        self.content = content
        self.planJSON = planJSON
        self.isOfflinePlan = isOfflinePlan
        self.imageData = imageData
    }

    var isUser: Bool { roleRaw == "user" }

    /// Decodes the stored plan JSON back into a GeneratedPlan, if present.
    var plan: GeneratedPlan? {
        guard let planJSON, let data = planJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GeneratedPlan.self, from: data)
    }

    static func encodePlan(_ plan: GeneratedPlan) -> String? {
        guard let data = try? JSONEncoder().encode(plan) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
