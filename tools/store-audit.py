#!/usr/bin/env python3
"""
Jeeves store audit: deterministic invariant checks over a pulled default.store.

Scope: the WHOLE store — travel, plans, events, workouts, lifts, runs,
reminders, todos, voice notes, check-ins, books, chat, and the plan-generation
log. Every check scans all rows with no date limits; only the pipeline
liveness checks may reference 'now'.

The GPT evals each see one surface (plans, chat, a scripted walkthrough); none
of them reads the travel rows themselves — which is exactly where a flight-
dressed-as-a-drive, a trip that ends before its last stay, and three
overlapping Bali trips lived undetected. This tool audits the store directly:
no API key, no judgment calls, red/green per invariant.

Usage:
    python3 tools/store-audit.py <path/to/default.store>
Pull first (device must be cabled):
    xcrun devicectl device copy from --device <UDID> \
      --domain-type appDataContainer --domain-identifier abhimanyusingh.me.Jeeves \
      --source "Library/Application Support/default.store" --destination default.store
    (repeat for default.store-wal and default.store-shm)

Exit code 0 = all invariants hold; 1 = at least one finding.
"""
import datetime
import sqlite3
import sys
from pathlib import Path

EPOCH = 978307200  # Core Data reference date offset from Unix epoch
DISTANT_PAST_CUTOFF = -60000000000  # anything this old is Date.distantPast


def ts(v):
    if v is None:
        return None
    if v < DISTANT_PAST_CUTOFF:
        return None  # Date.distantPast sentinel
    return datetime.datetime.fromtimestamp(v + EPOCH)


def day(dt):
    return dt.date() if dt else None


def fmt(dt):
    return dt.strftime("%a %d %b %H:%M") if dt else "-"


def leave_at(seg):
    """Mirror of LeaveBy.plan(for:): the instant the user must walk out."""
    total_flight = (seg["checkIn"] or 0) + (seg["sec"] or 0) + (seg["travel"] or 0) + (seg["buf"] or 0)
    total_drive = (seg["buf"] or 0) + (seg["travel"] or 0) + (seg["stops"] or 0)
    if seg["mode"] == "drive":
        if not seg["arriveBy"]:
            return None
        return seg["arriveBy"] - datetime.timedelta(minutes=total_drive)
    if not seg["departAt"]:
        return None
    return seg["departAt"] - datetime.timedelta(minutes=total_flight)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = Path(sys.argv[1])
    if not path.exists():
        sys.exit(f"No store at {path}")
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row

    trips = [dict(id=r["Z_PK"], uuid=r["ZID"], title=r["ZTITLE"] or "",
                  start=ts(r["ZSTARTDATE"]), end=ts(r["ZENDDATE"]))
             for r in db.execute("SELECT * FROM ZTRIP")]
    stays = [dict(tripUUID=r["ZTRIPID"], place=r["ZPLACE"] or "", address=r["ZADDRESS"] or "",
                  arrive=ts(r["ZARRIVEDATE"]), depart=ts(r["ZDEPARTDATE"]))
             for r in db.execute("SELECT * FROM ZTRIPSTAY")]
    segs = [dict(uuid=r["ZID"], tripUUID=r["ZTRIPID"], mode=r["ZMODERAW"], label=r["ZLABEL"] or "",
                 fromP=r["ZFROMPLACE"] or "", toP=r["ZTOPLACE"] or "",
                 departAt=ts(r["ZDEPARTAT"]), arriveBy=ts(r["ZARRIVEBY"]), arriveAt=ts(r["ZARRIVEAT"]),
                 checkIn=r["ZCHECKINMINUTES"], sec=r["ZSECURITYMINUTES"], buf=r["ZBUFFERMINUTES"],
                 stops=r["ZSTOPMINUTES"], travel=r["ZTRAVELMINUTES"], est=r["ZTRAVELISESTIMATED"])
            for r in db.execute("SELECT * FROM ZTRAVELSEGMENT")]
    plans = [dict(date=ts(r["ZDATE"]), planned=bool(r["ZGENERATEDPLANJSON"]))
             for r in db.execute("SELECT ZDATE, ZGENERATEDPLANJSON FROM ZDAILYPLANSTATE")]
    events = [dict(date=ts(r["ZDATE"]), title=r["ZTITLE"] or "", allDay=r["ZISALLDAY"],
                   start=r["ZSTARTMINUTE"], end=r["ZENDMINUTE"])
              for r in db.execute("SELECT * FROM ZDAILYEVENT")]

    trip_by_uuid = {t["uuid"]: t for t in trips}
    findings = []
    warnings = []

    def check(name, rows, describe, warn=False):
        label = "WARN" if warn else "FAIL"
        status = "PASS" if not rows else f"{label} ({len(rows)})"
        print(f"[{status:9}] {name}")
        for r in rows:
            print(f"            - {describe(r)}")
            (warnings if warn else findings).append(name)

    # 0. Sentinel dates: rows CloudKit or old builds minted with default
    #    (distantPast) dates crash every date comparison, so they get their
    #    own check and are excluded from the ones below.
    bad_trips = [t for t in trips if not t["start"] or not t["end"]]
    bad_stays = [s for s in stays if not s["arrive"] or not s["depart"]]
    check("no sentinel dates on trips/stays", bad_trips + bad_stays,
          lambda r: f"'{(r.get('title') or r.get('place') or '?')[:40]}' has default/distantPast dates")
    trips = [t for t in trips if t["start"] and t["end"]]
    stays = [s for s in stays if s["arrive"] and s["depart"]]
    trip_by_uuid = {t["uuid"]: t for t in trips}

    # 1. A trip covers its stays.
    bad = [(t, s) for s in stays
           for t in [trip_by_uuid.get(s["tripUUID"])] if t
           if (s["arrive"] and day(s["arrive"]) < day(t["start"]))
           or (s["depart"] and day(s["depart"]) > day(t["end"]))]
    check("trip covers its stays", bad,
          lambda p: f"'{p[0]['title'][:40]}' {day(p[0]['start'])}–{day(p[0]['end'])} vs stay '{p[1]['place'][:30]}' {day(p[1]['arrive'])}–{day(p[1]['depart'])}")

    # 2. A trip covers its journeys (leave-by day through arrival day).
    #    Day arithmetic runs in this machine's zone; near-midnight foreign
    #    legs can differ by one calendar day from the app's own computation,
    #    so this check allows a one-day boundary tolerance.
    bad = []
    for s in segs:
        t = trip_by_uuid.get(s["tripUUID"])
        if not t:
            continue
        leave = leave_at(s)
        landing = s["arriveBy"] if s["mode"] == "drive" else (s["arriveAt"] or s["departAt"])
        one_day = datetime.timedelta(days=1)
        if leave and day(leave) < day(t["start"] - one_day):
            bad.append((t, s, f"leaves {fmt(leave)} before trip start"))
        if landing and day(landing) > day(t["end"] + one_day):
            bad.append((t, s, f"lands {fmt(landing)} after trip end"))
    check("trip covers its journeys", bad,
          lambda p: f"'{p[0]['title'][:40]}': '{p[1]['label'][:40]}' {p[2]}")

    # 3. No overlapping trips — STRICT interior overlap: back-to-back trips
    #    sharing a boundary day (fly out on the last day) are normal.
    bad = [(a, b) for i, a in enumerate(trips) for b in trips[i + 1:]
           if a["end"] > b["start"] and b["end"] > a["start"]]
    check("no overlapping trips", bad,
          lambda p: f"'{p[0]['title'][:35]}' {day(p[0]['start'])}–{day(p[0]['end'])} overlaps '{p[1]['title'][:35]}' {day(p[1]['start'])}–{day(p[1]['end'])}")

    # 4. No duplicate stays (same trip, place+address, overlapping dates).
    bad = []
    for i, a in enumerate(stays):
        for b in stays[i + 1:]:
            if (a["tripUUID"] == b["tripUUID"] and a["place"] == b["place"]
                    and a["address"] == b["address"]
                    and a["depart"] >= b["arrive"] and b["depart"] >= a["arrive"]):
                bad.append((a, b))
    check("no duplicate stays", bad,
          lambda p: f"'{p[0]['place'][:35]}' {day(p[0]['arrive'])}–{day(p[0]['depart'])} duplicates {day(p[1]['arrive'])}–{day(p[1]['depart'])}")

    # 5. No self-transitions.
    bad = [s for s in segs if s["fromP"] and s["fromP"] == s["toP"]]
    check("no self-transitions", bad, lambda s: f"'{s['label'][:50]}' from == to")

    # 6. No flight whose journey time is hours of road (To isn't an airport).
    bad = [s for s in segs if s["mode"] != "drive" and (s["travel"] or 0) > 360]
    check("no flight with >6 h door-to-terminal", bad,
          lambda s: f"'{s['label'][:40]}' journey {s['travel']} min to '{s['toP'][:35]}'")

    # 7. Flight-shaped road transfers: a flight between two non-airport street
    #    addresses with a measured road time — the Bandipur case.
    bad = [s for s in segs
           if s["mode"] != "drive" and not s["est"] and (s["travel"] or 0) > 0
           and "airport" not in s["toP"].lower() and "terminal" not in s["toP"].lower()]
    check("flights whose To doesn't look like an airport", bad,
          lambda s: f"'{s['label'][:40]}' → '{s['toP'][:40]}' ({s['travel']} min measured)", warn=True)

    # 8. No phantom arrivals.
    bad = [s for s in segs if s["arriveAt"] and s["departAt"] and s["arriveAt"] <= s["departAt"]]
    check("no arrival at or before departure", bad,
          lambda s: f"'{s['label'][:40]}' departs {fmt(s['departAt'])} arrives {fmt(s['arriveAt'])}")

    # 9. No zero-journey chains on segments with a real time set.
    bad = [s for s in segs if (s["travel"] or 0) == 0 and (s["departAt"] or s["arriveBy"])]
    check("no journey missing its journey time", bad,
          lambda s: f"'{s['label'][:45]}' has a time but 0 min journey", warn=True)

    # 10. No stored plan under any trip-covered day.
    bad = []
    for p in plans:
        if not p["planned"] or not p["date"]:
            continue
        d = day(p["date"])
        for t in trips:
            if day(t["start"]) <= d <= day(t["end"]):
                bad.append((p, t))
                break
    check("no plans under trips", bad,
          lambda p: f"plan on {day(p[0]['date'])} under '{p[1]['title'][:40]}'")

    # 11. No orphaned stays/segments.
    live = set(trip_by_uuid)
    bad = [s for s in stays if s["tripUUID"] not in live]
    check("no orphaned stays", bad, lambda s: f"'{s['place'][:40]}' trip missing")
    bad = [s for s in segs if s["tripUUID"] not in live]
    check("no orphaned journeys", bad, lambda s: f"'{s['label'][:40]}' trip missing")

    # 12. No corrupted event times.
    bad = [e for e in events if not e["allDay"] and e["end"] < e["start"]]
    check("no events ending before they start", bad,
          lambda e: f"'{e['title'][:40]}' on {day(e['date'])}: {e['start']}→{e['end']} min")

    # ------------------------------------------------------------------
    # FULL-STORE INVARIANTS — every table, every row, no date limits.
    # ------------------------------------------------------------------
    workouts = [dict(uuid=r["ZID"], date=ts(r["ZDATE"]), title=r["ZTITLE"] or "",
                     type=r["ZTYPERAW"], state=r["ZSTATERAW"], source=r["ZSOURCERAW"],
                     dur=r["ZDURATIONMIN"], dist=r["ZDISTANCEKM"])
                for r in db.execute("SELECT * FROM ZWORKOUT")]
    lifts = [dict(uuid=r["ZID"], workoutUUID=r["ZWORKOUTID"], name=r["ZEXERCISENAME"] or "")
             for r in db.execute("SELECT * FROM ZLIFTSESSION")]
    sets_ = [dict(sessionUUID=r["ZSESSIONID"], reps=r["ZREPS"])
             for r in db.execute("SELECT * FROM ZLIFTSET")]
    runs = [dict(workoutUUID=r["ZWORKOUTID"]) for r in db.execute("SELECT * FROM ZRUNSESSION")]
    reminders = [dict(title=r["ZTITLE"] or "", enabled=r["ZENABLED"],
                      done=ts(r["ZCOMPLETEDAT"]), fire=ts(r["ZFIREAT"]),
                      rec=r["ZRECURRENCERAW"])
                 for r in db.execute("SELECT * FROM ZREMINDER")]
    todos = [dict(title=r["ZTITLE"] or "", done=ts(r["ZDONEAT"]), due=ts(r["ZDUEDATE"]))
             for r in db.execute("SELECT * FROM ZTODO")]
    notes = [dict(file=r["ZAUDIOFILENAME"] or "", dur=r["ZDURATIONSEC"],
                  transcript=r["ZTRANSCRIPT"] or "", date=ts(r["ZDATE"]))
             for r in db.execute("SELECT * FROM ZVOICENOTE")]
    checkins = [ts(r["ZDATE"]) for r in db.execute("SELECT ZDATE FROM ZCHECKIN")]
    books = [dict(title=r["ZTITLE"] or "", cur=r["ZCURRENTPAGE"], total=r["ZTOTALPAGES"])
             for r in db.execute("SELECT * FROM ZBOOK")]
    plan_dates = [ts(r["ZDATE"]) for r in db.execute("SELECT ZDATE FROM ZDAILYPLANSTATE")]
    ext_ids = [r["ZEXTERNALID"] for r in db.execute(
        "SELECT ZEXTERNALID FROM ZDAILYEVENT WHERE ZEXTERNALID != ''")]
    genlog = [dict(at=ts(r["ZSTARTEDAT"]), trigger=r["ZTRIGGERRAW"], outcome=r["ZOUTCOMERAW"])
              for r in db.execute("SELECT * FROM ZPLANGENERATIONLOG ORDER BY ZSTARTEDAT")]
    chat_count = db.execute("SELECT COUNT(*) FROM ZCHATTURN").fetchone()[0]
    empty_turns = db.execute(
        "SELECT COUNT(*) FROM ZCHATTURN WHERE (ZCONTENT IS NULL OR ZCONTENT = '')"
        " AND ZPLANJSON IS NULL AND ZIMAGEDATA IS NULL").fetchone()[0]

    workout_by_uuid = {w["uuid"]: w for w in workouts}
    lift_by_uuid = {l["uuid"]: l for l in lifts}

    bad = [l for l in lifts if l["workoutUUID"] is not None and l["workoutUUID"] not in workout_by_uuid]
    check("no lift sessions pointing at a missing workout", bad,
          lambda l: f"'{l['name'][:40]}' workout missing")
    bad = [s for s in sets_ if s["sessionUUID"] is not None and s["sessionUUID"] not in lift_by_uuid]
    check("no lift sets pointing at a missing session", bad,
          lambda s: f"set ({s['reps']} reps) session missing")
    bad = [r for r in runs if r["workoutUUID"] is not None and r["workoutUUID"] not in workout_by_uuid]
    check("no run sessions pointing at a missing workout", bad, lambda r: "run workout missing")

    bad = []
    for i, a in enumerate(workouts):
        for b in workouts[i + 1:]:
            if (a["date"] and b["date"] and day(a["date"]) == day(b["date"])
                    and a["type"] == b["type"] and a["dur"] == b["dur"] and a["uuid"] != b["uuid"]):
                bad.append((a, b))
    check("no cloned workouts (same day, type, duration)", bad,
          lambda p: f"'{p[0]['title'][:30]}' x2 on {day(p[0]['date'])} ({p[0]['dur']} min)", warn=True)

    bad = [w for w in workouts if (w["dur"] or 0) < 0 or (w["dur"] or 0) > 600
           or (w["dist"] or 0) < 0]
    check("no workouts with impossible numbers", bad,
          lambda w: f"'{w['title'][:30]}' {w['dur']} min / {w['dist']} km")
    bad = [w for w in workouts if w["state"] == "live" and w["date"]
           and (datetime.datetime.now() - w["date"]).days >= 1]
    check("no workouts stuck 'live' for over a day", bad,
          lambda w: f"'{w['title'][:30]}' live since {day(w['date'])}")

    active = [r for r in reminders if r["enabled"] and not r["done"]]
    seen = {}
    bad = []
    for r in active:
        key = r["title"].strip().lower()
        if key in seen:
            bad.append((seen[key], r))
        else:
            seen[key] = r
    check("no duplicate active reminders", bad,
          lambda p: f"'{p[0]['title'][:40]}' twice, fires {fmt(p[0]['fire'])} and {fmt(p[1]['fire'])}")
    bad = [r for r in active if r["fire"] and r["fire"] < datetime.datetime.now()
           and (r["rec"] or "none") == "none"]
    check("no one-shot reminders past their fire time still active", bad,
          lambda r: f"'{r['title'][:40]}' fired {fmt(r['fire'])}, never completed", warn=True)

    open_todos = [t for t in todos if not t["done"]]
    seen = {}
    bad = []
    for t in open_todos:
        key = t["title"].strip().lower()
        if key in seen:
            bad.append(t)
        else:
            seen[key] = t
    check("no duplicate open todos", bad, lambda t: f"'{t['title'][:45]}' twice", warn=True)

    bad = [n for n in notes if (n["dur"] or 0) <= 0]
    check("no zero-length voice notes", bad, lambda n: f"{n['file'][:40]} ({n['dur']} s)")
    bad = [n for n in notes if not n["transcript"].strip()]
    check("no voice notes without a transcript", bad,
          lambda n: f"{n['file'][:40]} on {day(n['date'])}", warn=True)
    seen = {}
    bad = [n for n in notes if n["file"] and (n["file"] in seen or seen.setdefault(n["file"], True) is None)]
    check("no duplicate voice-note files", bad, lambda n: n["file"][:50])

    day_counts = {}
    for d in checkins:
        if d:
            day_counts[day(d)] = day_counts.get(day(d), 0) + 1
    bad = [d for d, c in day_counts.items() if c > 1]
    check("no duplicate check-ins per day", bad, lambda d: f"{d} has multiple check-ins")

    bad = [b for b in books if (b["total"] or 0) > 0 and (b["cur"] or 0) > b["total"]]
    check("no books read past their last page", bad,
          lambda b: f"'{b['title'][:40]}' page {b['cur']}/{b['total']}")

    day_counts = {}
    for d in plan_dates:
        if d:
            day_counts[day(d)] = day_counts.get(day(d), 0) + 1
    bad = [d for d, c in day_counts.items() if c > 1]
    check("no duplicate plan-state rows per day", bad, lambda d: f"{d} has multiple rows")

    seen = {}
    bad = [e for e in ext_ids if e in seen or seen.setdefault(e, True) is None]
    check("no duplicate calendar externalIDs", bad, lambda e: str(e)[:50])

    check("no empty chat turns", [None] * empty_turns, lambda _: "turn with no content, plan, or image")
    check("chat history within bounds", [None] * (1 if chat_count > 5000 else 0),
          lambda _: f"{chat_count} turns stored — consider retention policy", warn=True)

    # Pipeline liveness — inherently recency-based; the only checks allowed
    # to look at 'now'. Everything above scans all history unconditionally.
    dated_log = [g for g in genlog if g["at"]]
    if dated_log:
        last = dated_log[-1]
        age = (datetime.datetime.now() - last["at"]).days
        check("plan generation ran recently", [None] * (1 if age > 3 else 0),
              lambda _: f"last entry {age} days ago ({last['trigger']}/{last['outcome']})", warn=True)
        last_auto = next((g for g in reversed(dated_log) if g["trigger"] == "autoPlan"), None)
        auto_age = (datetime.datetime.now() - last_auto["at"]).days if last_auto else 9999
        check("overnight auto-planner alive", [None] * (1 if auto_age > 3 else 0),
              lambda _: "no autoPlan entry in the last 3 days" if last_auto
              else "no autoPlan entry has EVER been logged", warn=True)
        tail = dated_log[-5:]
        streak = all(g["outcome"] in ("offlineFallback", "abandoned", "pending") for g in tail)
        check("no failure streak in plan generation", [None] * (1 if streak and len(tail) == 5 else 0),
              lambda _: "last 5 generations all failed/offline/abandoned: "
              + ", ".join(g["outcome"] for g in tail))
    bad = [g for g in genlog if g["outcome"] == "pending"]
    check("no generations still 'pending'", bad,
          lambda g: f"{fmt(g['at'])} ({g['trigger']}) never resolved", warn=True)

    n, w = len(findings), len(warnings)
    if n == 0 and w == 0:
        print("\nCLEAN — every invariant holds")
    else:
        print(f"\n{n} failure(s) across {len(set(findings))} invariant(s), {w} warning(s)")
    sys.exit(0 if n == 0 else 1)


if __name__ == "__main__":
    main()
