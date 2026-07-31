//
//  StayWindow.swift
//  Jeeves
//
//  Hotel policy arithmetic for a transition between two stays.
//
//  A stay used to be whole days only, so the auto-created drive between two
//  hotels had nothing to aim at and hardcoded "arrive by noon" — which is
//  after most checkouts and before most check-ins, i.e. wrong at both ends.
//  Real itineraries are shaped by these windows: you cannot leave later than
//  checkout, and arriving before check-in means waiting in a lobby.
//
//  Pure and unit-tested, per the standing rule that every hardcoded default
//  gets a helper with tests rather than a magic number in a view.
//

import Foundation

enum StayWindow {
    /// Common Indian hotel windows, used when the user hasn't said otherwise.
    static let defaultCheckin = 14 * 60          // 14:00
    static let defaultCheckout = 11 * 60 + 30    // 11:30

    /// What a drive between two hotels actually looks like once both policies
    /// are respected.
    struct Transition: Equatable {
        /// When to leave the first hotel — never later than its checkout.
        var leaveMinute: Int
        /// When the drive gets in.
        var arriveMinute: Int
        /// Minutes spent waiting because check-in hadn't opened yet (0 when
        /// the drive lands after it).
        var waitMinutes: Int
        /// The arrival deadline to hand the leave-by calculator.
        var arriveByMinute: Int
        /// Nil when both windows are satisfied; otherwise the honest caveat —
        /// the model must repeat this rather than quietly picking one end.
        var caveat: String?
    }

    /// Leaving at checkout is the latest you can go; everything follows from
    /// that. If the drive is short enough to land before check-in opens, that
    /// is a real wait and gets said out loud instead of being papered over by
    /// pretending the arrival is later than it is.
    static func transition(checkoutMinute: Int = defaultCheckout,
                           checkinMinute: Int = defaultCheckin,
                           travelMinutes: Int) -> Transition {
        let travel = max(0, travelMinutes)
        let leave = checkoutMinute
        let arrive = leave + travel

        if arrive >= checkinMinute {
            return Transition(leaveMinute: leave, arriveMinute: arrive,
                              waitMinutes: 0, arriveByMinute: arrive, caveat: nil)
        }

        // Lands early. Leaving later than checkout isn't an option, so the
        // gap is real — name it in the hotel's own terms.
        let wait = checkinMinute - arrive
        let caveat = "The drive takes \(hhmm(travel)); leaving at checkout (\(clock(checkoutMinute))) "
            + "gets you there \(clock(arrive)), which is \(hhmm(wait)) before check-in opens at "
            + "\(clock(checkinMinute)). Say if you'd rather leave later and skip the wait, or "
            + "arrange an early check-in."
        return Transition(leaveMinute: leave, arriveMinute: arrive,
                          waitMinutes: wait, arriveByMinute: checkinMinute, caveat: caveat)
    }

    /// Does a departure leave time for breakfast? Breakfast is a preference,
    /// not a constraint — this only ever produces a note.
    static func breakfastNote(leaveMinute: Int, travelToBreakfastEnd: Int? = nil,
                              breakfastEnds: Int) -> String? {
        guard leaveMinute < breakfastEnds else { return nil }
        return "You'd be leaving at \(clock(leaveMinute)), before breakfast finishes at "
            + "\(clock(breakfastEnds))."
    }

    /// "14:00"
    static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", (minute / 60) % 24, minute % 60)
    }

    /// "2h 30m" / "45m"
    static func hhmm(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
