//
//  EvidenceWalkthroughTests.swift
//  JeevesUITests
//
//  Walks the shipped app and photographs it. Grades nothing — the judging is
//  `tools/screen-judge.py`'s job, and keeping the two apart is the point: the
//  capture cannot decide what counts as built.
//
//  Navigation is by accessibility LABEL, because the app has no accessibility
//  identifiers anywhere (36 labels, 0 identifiers). That makes a renamed label
//  indistinguishable from a missing screen — so every step records `reachable`
//  and the collator surfaces unreachable steps at the top of the report.
//
//  NOTHING IN HERE MAY CALL `.tap()` DIRECTLY. XCUIElement.tap() on an element
//  that does not exist raises, and a raised error ends the test — so one missing
//  control would cost every screen after it. The first run of this file did
//  exactly that: it died on step 21 of ~40 because a NavigationLink was not a
//  Button. `tapAny` checks first and returns false instead.
//

import XCTest

final class EvidenceWalkthroughTests: XCTestCase {

    private var app: XCUIApplication!
    private var rec: EvidenceRecorder!

    override func setUpWithError() throws {
        // One missing screen must not cost us the other forty-five.
        continueAfterFailure = true

        app = XCUIApplication()
        app.launchArguments = [
            "-JeevesEvidenceRun",
            // NSArgumentDomain outranks persisted defaults, so these pin
            // @AppStorage without touching the store.
            "-jeeves.catchUp.lastShown", "0",
            "-jeeves.remindersEnabled", "YES",
            "-AppleLanguages", "(en_IN)",
            "-AppleLocale", "en_IN",
        ]
        app.launchEnvironment["TZ"] = "Asia/Kolkata"
        app.launch()
        rec = EvidenceRecorder(app: app, test: self)
    }

    override func tearDownWithError() throws {
        rec?.attachManifest()
    }

    /// Smoke: the five tabs. Run before trusting the full walk — it proves the
    /// app launches under UI test (the CloudKit gate), that the permission alert
    /// stays away, and that attachments survive to disk.
    func testSmokeTabs() {
        rec.step("launch")
        for tab in ["Progress", "Planner", "Tasks", "Fitness", "Library"] {
            rec.step("tab.\(tab.lowercased())") { self.tapAny(tab) }
        }
    }

    /// Every screen reachable without a network.
    func testEveryScreenShallow() {
        rec.step("launch")

        // MARK: tabs, at rest and scrolled. Lazy content that has never been
        // laid out does not exist in the tree, so one capture of a long screen
        // under-reports what was built.
        for tab in ["Progress", "Planner", "Tasks", "Fitness", "Library"] {
            let key = tab.lowercased()
            rec.step("tab.\(key)") { self.tapAny(tab) }
            rec.step("tab.\(key).mid") { self.scrollDownOnce(); self.scrollDownOnce(); return true }
            rec.step("tab.\(key).scrolled") { self.scrollToBottom(); return true }
        }

        // MARK: hamburger routes — reachable from any tab, the cheapest breadth
        // in the app.
        for (label, key) in [("App Health", "health"), ("History", "history"),
                             ("Adherence", "adherence")] {
            rec.step("stats.\(key)") {
                self.tapAny("Menu") && self.tapAny("Stats") && self.tapAny(label)
            }
            rec.step("stats.\(key).scrolled") { self.scrollToBottom(); return true }
            dismissSheet()
        }

        rec.step("journeys") { self.tapAny("Menu") && self.tapAny("Journeys") }
        dismissSheet()

        rec.step("settings") { self.tapAny("Menu") && self.tapAny("Settings") }
        rec.step("settings.mid") { self.scrollDownOnce(); self.scrollDownOnce(); return true }
        rec.step("settings.scrolled") { self.scrollToBottom(); return true }

        // The routine catalog carries the WEEKDAY CHIPS and each activity's
        // DURATION — two requirements that were graded "unknown" purely because
        // this screen was never reached.
        rec.step("settings.sync_calendars") { self.tapAny("Sync calendars now") }

        rec.step("settings.routine") { self.tapAny("Daily routine") }
        rec.step("settings.routine.scrolled") { self.scrollToBottom(); return true }
        rec.step("settings.routine.activity") { self.tapAny("Chores") }
        dismissSheet()

        // The calendar sheet: whether one button syncs every account.
        rec.step("settings.calendars") {
            self.tapAny("Menu") && self.tapAny("Settings") && self.tapAny("Choose calendars…")
        }
        dismissSheet()

        // MARK: chat and the morning offer.
        rec.step("chat") { self.tapAny("Ask Jeeves") }
        rec.step("chat.morning_card") { self.tapAny("Pick today") }
        rec.step("chat.morning_card.reorder") { self.tapAny("Reorder activities") }
        rec.step("chat.morning_card.scrolled") { self.scrollToBottom(); return true }
        rec.step("chat.menu") { self.tapAny("More") }
        dismissSheet()
        dismissSheet()

        // MARK: planner surfaces gated on the seeded plan.
        rec.step("planner") { self.tapAny("Planner") }
        rec.step("planner.editor") { self.tapAny("Edit") }
        rec.step("planner.editor.scrolled") { self.scrollToBottom(); return true }
        dismissSheet()

        // Yesterday's plan is the OFFLINE one. The banner is a persistent
        // property of the stored plan, invisible to a walk that only ever looks
        // at an online day.
        //
        // Tapping "Jump to a date" and dismissing does NOT move the day — it
        // opens a picker and throws it away, which is why the previous run still
        // photographed today and the marker still graded absent. The date strip
        // itself is a row of buttons labelled "FRI, 7", so tap yesterday's.
        rec.step("planner.yesterday") { self.tapAny(self.dateStripLabel(daysAgo: 1)) }
        rec.step("planner.offline_marker") { self.scrollToTop(); return true }

        rec.step("planner.activity_picker") { self.tapAny("Choose this day's activities") }
        dismissSheet()

        rec.step("planner.travel") { self.tapAny("Travel") }
        dismissSheet()

        rec.step("planner.date_jump") { self.tapAny("Jump to a date") }
        dismissSheet()

        rec.step("planner.add_event") { self.tapAny("Add") }
        dismissSheet()

        // MARK: tasks + fitness + library detail.
        // The reminder editor carries Once / Daily / Weekly / Every X Days —
        // graded "unknown" last run because the sheet never opened.
        rec.step("tasks.reminders") { self.tapAny("Tasks") }
        rec.step("tasks.add_reminder") { self.tapAny("New reminder") }
        rec.step("tasks.add_reminder.scrolled") { self.scrollToBottom(); return true }
        dismissSheet()
        rec.step("tasks.todos") { self.tapAny("To-dos") }
        rec.step("tasks.add_todo") { self.tapAny("New to-do") }
        dismissSheet()

        rec.step("fitness") { self.tapAny("Fitness") }
        rec.step("fitness.scrolled") { self.scrollToBottom(); return true }

        rec.step("library") { self.tapAny("Library") }
        rec.step("library.scrolled") { self.scrollToBottom(); return true }
    }

    // MARK: helpers

    /// Tap the first element carrying `label`, whatever its type, and say
    /// whether anything was there. SwiftUI renders NavigationLinks, list rows
    /// and plain buttons as different element types for the same visual control,
    /// so keying on `.buttons` alone reports built screens as missing.
    /// Find `label` anywhere on the current screen, scrolling if it takes it.
    ///
    /// Two ways this used to report a built control as missing: the previous
    /// step left the screen scrolled to its bottom, and long screens keep most
    /// of their controls off-view. So: try here, go to the top and try, then
    /// walk down in small steps. Big drags overshoot — Settings' whole middle
    /// section was jumped clean over by a four-drag scroll.
    @discardableResult
    private func tapAny(_ label: String, timeout: TimeInterval = 3) -> Bool {
        if tapOnce(label, timeout: timeout) { return true }
        scrollToTop()
        if tapOnce(label, timeout: 1) { return true }
        for _ in 0..<6 {
            scrollDownOnce()
            if tapOnce(label, timeout: 0.5) { return true }
        }
        return false
    }

    private func scrollDownOnce() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func tapOnce(_ label: String, timeout: TimeInterval) -> Bool {
        for query in [app.buttons, app.staticTexts, app.cells, app.otherElements] {
            let element = query[label].firstMatch
            if element.waitForExistence(timeout: timeout) && element.isHittable {
                element.tap()
                return true
            }
        }
        return false
    }

    /// Close whatever modal is up, and CONFIRM it closed.
    ///
    /// The first full run drove one sheet open and then photographed it
    /// twenty-six times, because the drag-to-dismiss silently failed and
    /// nothing checked. Sheets in this app carry a real "Close"/"Done" button
    /// far more often than they support the drag, so try those first and fall
    /// back to the gesture — then verify against the tab bar, which only exists
    /// when nothing is covering it.
    @discardableResult
    private func dismissSheet() -> Bool {
        for _ in 0..<3 {
            if atRoot() { return true }
            // A sheet scrolled to its bottom will not drag-dismiss, and its
            // Close button is off-screen — which is how Settings swallowed
            // nineteen consecutive steps.
            scrollToTop()
            var closed = false
            for label in ["Close", "Done", "Cancel", "Minimise chat"] {
                let button = app.buttons[label].firstMatch
                if button.exists && button.isHittable { button.tap(); closed = true; break }
            }
            if !closed {
                let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
                let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
                top.press(forDuration: 0.05, thenDragTo: bottom)
            }
            _ = app.wait(for: .runningForeground, timeout: 1)
        }
        return atRoot()
    }

    /// The tab bar is only reachable with no sheet over it, so it is the
    /// cheapest proof that we are back at the root.
    private func atRoot() -> Bool {
        let tab = app.buttons["Planner"].firstMatch
        return tab.exists && tab.isHittable
    }

    /// The date strip renders each day as a button labelled like "FRI, 7".
    private func dateStripLabel(daysAgo: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let weekday = DateFormatter()
        weekday.dateFormat = "EEE"
        weekday.locale = Locale(identifier: "en_IN")
        return "\(weekday.string(from: day).uppercased()), \(Calendar.current.component(.day, from: day))"
    }

    private func scrollToTop() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        for _ in 0..<5 { start.press(forDuration: 0.05, thenDragTo: end) }
    }

    private func scrollToBottom() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        for _ in 0..<4 { start.press(forDuration: 0.05, thenDragTo: end) }
    }
}
