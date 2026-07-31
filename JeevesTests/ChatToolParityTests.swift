//
//  ChatToolParityTests.swift
//  JeevesTests
//
//  The tool roster lives in two hand-maintained places: the schemas the model
//  is shown (JeevesChatService.toolSchemas) and the dispatch switch
//  (JeevesChatView.executeTool, mirrored in handledToolNames). A tool present
//  on one side only fails at runtime as "Unknown tool" — this pins the two
//  lists to each other so the drift fails the suite instead.
//

import XCTest
@testable import Jeeves

@MainActor
final class ChatToolParityTests: XCTestCase {

    private var schemaNames: Set<String> {
        Set(JeevesChatService.toolSchemas.compactMap { $0["name"] as? String })
    }

    func testEveryAdvertisedToolIsDispatched() {
        let missing = schemaNames.subtracting(ChatToolExecutor.handledToolNames)
        XCTAssertTrue(missing.isEmpty,
                      "advertised to the model but not dispatched: \(missing.sorted())")
    }

    func testEveryDispatchedToolIsAdvertised() {
        let phantom = ChatToolExecutor.handledToolNames.subtracting(schemaNames)
        XCTAssertTrue(phantom.isEmpty,
                      "dispatched but never advertised to the model: \(phantom.sorted())")
    }

    func testRosterIsNonTrivial() {
        XCTAssertGreaterThanOrEqual(schemaNames.count, 20, "the roster shrank unexpectedly")
    }
}
