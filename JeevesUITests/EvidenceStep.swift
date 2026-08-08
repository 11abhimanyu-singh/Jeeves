//
//  EvidenceStep.swift
//  JeevesUITests
//
//  One step of the walkthrough = one screen state, captured twice over: a PNG
//  and the accessibility tree behind it.
//
//  The rule that shapes this file: A STEP NEVER FAILS THE TEST. If a screen was
//  never built, or a label was renamed, the step records `reachable: false` and
//  the walk carries on. An `XCTFail` here would abort the run and lose the other
//  forty-five screens — turning one missing screen into no evidence at all,
//  which is precisely the failure mode this whole harness exists to end.
//

import XCTest

/// Written alongside the attachments so the collator can order steps and know
/// what each one was trying to reach.
struct StepRecord: Codable {
    let index: Int
    let label: String
    let reachable: Bool
    let changed: Bool
    let elementCount: Int
    let onScreenCount: Int
    let note: String
}

final class EvidenceRecorder {
    private(set) var steps: [StepRecord] = []
    private var index = 0
    private var lastFingerprint = 0
    private let app: XCUIApplication
    private unowned let test: XCTestCase

    init(app: XCUIApplication, test: XCTestCase) {
        self.app = app
        self.test = test
    }

    /// Capture the current screen under `label`.
    ///
    /// - Parameters:
    ///   - expect: an element that proves we actually arrived. Nil means "capture
    ///     whatever is on screen" (used for the launch state).
    ///   - open: the navigation that gets us there, run before waiting.
    @discardableResult
    func step(_ label: String,
              timeout: TimeInterval = 4,
              open: () -> Bool = { true }) -> Bool {
        index += 1
        // The navigation reports whether it found anything to tap. Discarding
        // that was how the first full run produced 39 confident steps of which
        // 26 were the same stuck sheet.
        let navigated = open()
        _ = app.wait(for: .runningForeground, timeout: 1)

        var note = navigated ? "" : "nothing to tap for this step"
        capture(label: label, reachable: navigated, note: note)
        return navigated
    }

    private func capture(label: String, reachable: Bool, note incoming: String) {
        var note = incoming
        let stem = String(format: "%03d__%@", index, label.replacingOccurrences(of: " ", with: "_"))

        // One screenshot, used for both the frame geometry and the attachment.
        // `XCTAttachment(screenshot:)` re-encodes to JPEG unless quality is
        // .original; the data initializer is the only one that guarantees PNG,
        // and a vision judge should not be reading compression artefacts.
        let shot = XCUIScreen.main.screenshot()
        let png = shot.pngRepresentation

        var elementCount = 0
        var onScreenCount = 0
        var labelPrint = 0
        if let snap = try? app.snapshot() {
            let tree = A11yDump.node(from: snap, screen: CGRect(origin: .zero, size: shot.image.size))
            elementCount = A11yDump.count(tree)
            onScreenCount = countOnScreen(tree)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(tree) {
                attach(data, name: "\(stem)__a11y.json", uti: "public.json")
                labelPrint = labels(of: tree).hashValue
            }
        } else {
            note = note.isEmpty ? "snapshot unavailable" : note + "; snapshot unavailable"
        }

        attach(png, name: "\(stem)__screen.png", uti: "public.png")

        // THE BACKSTOP. A tap can "succeed" and change nothing — a modal eats
        // it, a control is decorative, a sheet refuses to dismiss. If this
        // screen is the same as the last one, say so: an unnoticed stuck sheet
        // turns every later step into a confident photograph of the wrong
        // screen, which is worse than having no evidence at all.
        //
        // BOTH the tree AND the pixels, because `app.snapshot()` only sees this
        // process. The iOS notification-permission alert belongs to SpringBoard,
        // so `launch` and `tab.progress` hashed IDENTICALLY on their labels
        // while differing across 88% of their pixels — and once the judge
        // started acting on this flag, that made it drop the CLEAN screenshot
        // and keep the one with a system dialog over it. Same screen means the
        // same on both counts; differing on either is a different screen.
        let fingerprint = "\(labelPrint)|\(png.hashValue)".hashValue
        let changed = !(fingerprint == lastFingerprint && index > 1)
        if !changed {
            note = note.isEmpty ? "screen unchanged from previous step"
                                : note + "; screen unchanged from previous step"
        }
        lastFingerprint = fingerprint

        steps.append(StepRecord(index: index, label: label, reachable: reachable,
                                changed: changed,
                                elementCount: elementCount, onScreenCount: onScreenCount,
                                note: note))
    }

    /// The manifest of the whole walk, attached once at the end.
    func attachManifest() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(steps) {
            attach(data, name: "000__walk__steps.json", uti: "public.json")
        }
    }

    private func attach(_ data: Data, name: String, uti: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: uti)
        attachment.name = name
        // Default is .deleteOnSuccess, which would throw away every artefact on
        // a green run — the exact opposite of what evidence means.
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    /// Labels only — frames shift by a pixel between identical screens, so
    /// hashing the whole tree would never match.
    private func labels(of node: A11yNode) -> String {
        ([node.type, node.label, node.value].joined(separator: "|"))
            + node.children.map { labels(of: $0) }.joined()
    }

    private func countOnScreen(_ node: A11yNode) -> Int {
        (node.onScreen ? 1 : 0) + node.children.reduce(0) { $0 + countOnScreen($1) }
    }
}
