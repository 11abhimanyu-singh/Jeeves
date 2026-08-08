//
//  PaletteContrastTests.swift
//  JeevesTests
//
//  The palette used to carry its contrast rule in a code comment: "use textSoft
//  for small regular text on cards". tools/visual-judge.py then found textMuted
//  on `surface` and `surfaceDeep` across six screens — and following the comment
//  would not have helped, because textSoft was itself 4.44:1 on surfaceDeep.
//
//  By this repo's own rubric a rule stated only in a comment is a request. This
//  file is what makes it a rule: every text tier must clear WCAG AA on every
//  ground it can land on, so a designer's eye is never the only thing standing
//  between a token and an unreadable screen.
//
//  KNOWN LIMIT, stated rather than implied: this checks the palette, not its
//  use. It cannot see a view that paints `accent` — a FILL token, 2.43:1 on
//  surfaceDeep — as body text. Only the visual judge sees that, and only on a
//  screen it has captured.
//

import XCTest
import SwiftUI
@testable import Jeeves

final class PaletteContrastTests: XCTestCase {

    /// WCAG 2.2 relative luminance (§ "relative luminance"), sRGB.
    private func luminance(_ color: Color) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func ratio(_ fg: Color, on bg: Color) -> Double {
        let a = luminance(fg), b = luminance(bg)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Every ground a card or row can sit on. A token is only safe if it clears
    /// the DARKEST of these — checking against `bg` alone is what let the old
    /// values through.
    private let grounds: [(String, Color)] = [
        ("bg", .bg), ("surface", .surface), ("surfaceDeep", .surfaceDeep),
    ]

    private let textTiers: [(String, Color)] = [
        ("textPrimary", .textPrimary), ("textSoft", .textSoft), ("textMuted", .textMuted),
    ]

    func testEveryTextTierClearsAAOnEveryGround() {
        for (fgName, fg) in textTiers {
            for (bgName, bg) in grounds {
                let r = ratio(fg, on: bg)
                XCTAssertGreaterThanOrEqual(
                    r, 4.5,
                    "\(fgName) on \(bgName) is \(String(format: "%.2f", r)):1 — small text needs 4.5:1")
            }
        }
    }

    /// accentDeep is the link/emphasis colour and is read as text, so it is held
    /// to the text bar too.
    func testAccentDeepIsReadableAsTextEverywhere() {
        for (bgName, bg) in grounds {
            let r = ratio(.accentDeep, on: bg)
            XCTAssertGreaterThanOrEqual(r, 4.5, "accentDeep on \(bgName) is \(String(format: "%.2f", r)):1")
        }
    }

    /// White on the accent fill — every primary button in the app.
    func testWhiteOnTheAccentFillClearsAA() {
        XCTAssertGreaterThanOrEqual(ratio(.white, on: .accent), 3.0,
                                    "button labels are 15pt semibold — large-text AA")
        XCTAssertGreaterThanOrEqual(ratio(.white, on: .accentDeep), 4.5)
    }

    /// The tiers have to stay visibly distinct, or the fix quietly collapses the
    /// hierarchy into one grey and every screen loses its emphasis.
    func testTheTiersRemainDistinguishableFromEachOther() {
        let deep = Color.surfaceDeep
        XCTAssertGreaterThan(ratio(.textSoft, on: deep) - ratio(.textMuted, on: deep), 0.5,
                             "textSoft must read as a step stronger than textMuted, not the same grey")
        XCTAssertGreaterThan(ratio(.textPrimary, on: deep) - ratio(.textSoft, on: deep), 2.0)
    }

    /// The sage "Owned"/"Liked" pills carry a label on their own light ground.
    func testTheSagePillLabelIsReadable() {
        XCTAssertGreaterThanOrEqual(ratio(.sageDeep, on: .sageLight), 4.5)
    }
}
