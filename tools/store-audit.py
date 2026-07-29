#!/usr/bin/env python3
"""
Jeeves store audit: deterministic invariant checks over a pulled default.store.

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

    n, w = len(findings), len(warnings)
    if n == 0 and w == 0:
        print("\nCLEAN — every invariant holds")
    else:
        print(f"\n{n} failure(s) across {len(set(findings))} invariant(s), {w} warning(s)")
    sys.exit(0 if n == 0 else 1)


if __name__ == "__main__":
    main()
