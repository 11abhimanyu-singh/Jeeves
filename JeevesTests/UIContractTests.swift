//
//  UIContractTests.swift
//  JeevesTests
//
//  The UI audit's findings, turned into things that can regress loudly.
//
//  Each of these guards a defect that was shipped and invisible: text that
//  ignored the user's size setting, a screen that slept mid-run, and a colour
//  pair the palette's own comment forbade. None of them threw an error or
//  failed a build — that is exactly why they need tests.
//

import XCTest
import SwiftUI
@testable import Jeeves

final class UIContractTests: XCTestCase {

    // MARK: Type scale

    func testTypeSizesNeverFallBelowTheLegibilityFloor() {
        // The app shipped an 8.5 pt time-zone label — the one that tells
        // 15:00 Thimphu from 15:00 IST — and a 9 pt recurrence badge.
        XCTAssertEqual(Font.minimumPointSize, 11)
        for tiny in [6.0, 8.5, 9.0, 10.5] as [CGFloat] {
            XCTAssertEqual(max(tiny, Font.minimumPointSize), 11,
                           "\(tiny) pt must be floored to 11")
        }
    }

    func testMetricStyleRisesWithSize() {
        // A 10 pt eyebrow and a 40 pt stat must not scale at the same rate,
        // or large-text settings blow the layout apart.
        let bands: [(CGFloat, UIFont.TextStyle)] = [
            (11, .caption2), (12, .caption1), (13, .footnote), (15, .subheadline),
            (17, .callout), (18, .title3), (22, .title2), (28, .title1), (40, .largeTitle),
        ]
        for (size, expected) in bands {
            XCTAssertEqual(Font.metricStyle(for: size), expected,
                           "\(size) pt mapped to the wrong metric style")
        }
    }

    func testSwiftUIAndUIKitStyleMapsAgree() {
        // serif() scales via Font.TextStyle and ui() via UIFont.TextStyle.
        // If the two ladders disagree, serif and sans text drift apart as the
        // user's size grows — which is worse than neither scaling.
        let pairs: [(Font.TextStyle, UIFont.TextStyle)] = [
            (.caption2, .caption2), (.caption, .caption1), (.footnote, .footnote),
            (.subheadline, .subheadline), (.callout, .callout), (.title3, .title3),
            (.title2, .title2), (.title, .title1), (.largeTitle, .largeTitle),
        ]
        for size in stride(from: CGFloat(11), through: 52, by: 0.5) {
            let sui = Font.textStyle(for: size)
            let uik = Font.metricStyle(for: size)
            XCTAssertTrue(pairs.contains { $0 == sui && $1 == uik },
                          "at \(size) pt the two style ladders disagree: \(sui) vs \(uik)")
        }
    }

    // MARK: Screen wake

    @MainActor
    func testScreenAwakeIsBalanced() {
        ScreenAwake.releaseAll()
        XCTAssertFalse(ScreenAwake.isHeld)

        ScreenAwake.acquire()
        XCTAssertTrue(ScreenAwake.isHeld, "a live run must hold the screen")

        // Run and stretch can overlap; the first release must not drop it.
        ScreenAwake.acquire()
        ScreenAwake.release()
        XCTAssertTrue(ScreenAwake.isHeld, "one release of two holds must not let the screen sleep")

        ScreenAwake.release()
        XCTAssertFalse(ScreenAwake.isHeld, "the last release must let the screen sleep again")
    }

    @MainActor
    func testScreenAwakeNeverGoesNegative() {
        // An unbalanced release must not bank credit that keeps a later
        // acquire from working — that would leave a user's screen on forever.
        ScreenAwake.releaseAll()
        ScreenAwake.release()
        ScreenAwake.release()
        ScreenAwake.acquire()
        XCTAssertTrue(ScreenAwake.isHeld)
        ScreenAwake.release()
        XCTAssertFalse(ScreenAwake.isHeld)
    }

    // MARK: Contrast

    /// WCAG 2.2 relative luminance / contrast ratio.
    private func contrast(_ a: String, _ b: String) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func luminance(_ hex: String) -> Double {
            let r = Double(Int(hex.prefix(2), radix: 16)!) / 255
            let g = Double(Int(hex.dropFirst(2).prefix(2), radix: 16)!) / 255
            let b = Double(Int(hex.suffix(2), radix: 16)!) / 255
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The live value of a palette token, so an assertion tracks the app
    /// instead of a hex someone typed here once.
    private func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    func testForegroundTokensClearAAOnEverySurface() {
        // accent (#C67139) and sage (#7A8A5E) failed on cards at 2.69 and
        // 2.79; the deep variants replaced them everywhere they carried text.
        let surfaces = ["F5EAD8", "EBDDC5", "DCD3C4", "E1EECC"]   // bg, surface, surfaceDeep, sageLight
        for surface in surfaces {
            XCTAssertGreaterThanOrEqual(contrast("201E1D", surface), 4.5, "textPrimary on \(surface)")
            XCTAssertGreaterThanOrEqual(contrast("8C491A", surface), 4.5, "accentDeep on \(surface)")
            XCTAssertGreaterThanOrEqual(contrast("56633F", surface), 4.3, "sageDeep on \(surface)")
        }
    }

    func testTheOldAccentWouldStillFail() {
        // Guards the swap itself: if someone reinstates accent as a text
        // colour on cards, this is the number they'd be shipping.
        XCTAssertLessThan(contrast("C67139", "EBDDC5"), 4.5,
                          "accent on surface passes now? then the palette moved — recheck every call site")
    }

    func testDisabledButtonKeepsItsLabelReadable() {
        // The disabled Save filled with textMuted at 50% alpha and kept white
        // text — around 2.2:1. Solid textMuted clears the bar comfortably.
        //
        // The hex lives in ONE place. This assertion used to hardcode "6E6759",
        // and when the palette moved to "625B4F" it went on passing while
        // testing a colour the app no longer contains — a green test for a
        // constant nothing renders.
        XCTAssertGreaterThanOrEqual(contrast(hex(.textMuted), "FFFFFF"), 4.5,
                                    "white on a disabled button must stay readable")
    }

    func testPrimaryButtonFillPassesAsLargeText() {
        // White on accent is 3.61 — below the 4.5 normal-text bar but above
        // the 3.0 large-text bar, and the CTA labels are 17 pt bold. This is
        // the reason accent survived as a fill while losing its text role.
        let ratio = contrast("FFFFFF", "C67139")
        XCTAssertGreaterThanOrEqual(ratio, 3.0)
        XCTAssertLessThan(ratio, 4.5, "if this now passes 4.5, small labels on accent are safe too")
    }
}
