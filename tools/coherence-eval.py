#!/usr/bin/env python3
"""
Jeeves coherence eval: a third party reads the WHOLE state and hunts
incoherence — then proposes NEW invariants for the deterministic audit.

Division of labor: store-audit.py enforces KNOWN invariants forever, for
free. This pass exists to find the UNKNOWN ones — a judge handed every row
can notice "this trip is titled 'Bali + Bali + Bali'" or "these two tables
disagree about the same day" without anyone having predicted the failure.
Every invariant it proposes is reviewed and, if sound, added to
store-audit.py, so each run of this makes the free layer stronger.

Usage:
    python3 tools/store-dump.py default.store dump.json
    OPENAI_API_KEY=sk-... python3 tools/coherence-eval.py dump.json
Writes dump.coherence.json beside the input. Key from env only, never stored.
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

API = "https://api.openai.com/v1/chat/completions"

RUBRIC = """You are auditing the COMPLETE datastore of "Jeeves", a single-user
personal iOS planner (SwiftUI/SwiftData, one user, Bengaluru/IST). You receive
every row of every table — nothing was sampled or filtered.

Data model, briefly: DAILYPLANSTATE holds one generated day-plan per date;
DAILYEVENT calendar/manual events (all-day rows have startMinute=endMinute=0,
spanEndDate for multi-day, externalID for Google sync); TRIP owns date ranges
where the planner stands down, with TRIPSTAY lodging rows and TRAVELSEGMENT
journeys (flight: departAt on origin clock; drive: arriveBy on DESTINATION
clock; leave-by = departAt/arriveBy minus checkIn+security+travel+buffer+stops
as applicable); WORKOUT unifies lifts/runs/walks (state live→needsDetail→done,
source watch/phone/manual) with LIFTSESSION/LIFTSET/RUNSESSION children by
UUID; CHECKIN one per day derived from workouts; REMINDER/TODO tasks;
VOICENOTE transcribed audio; CHATTURN the assistant conversation;
PLANGENERATIONLOG one row per plan-generation attempt (trigger
planner/chat/autoPlan, outcome success/repaired/offlineFallback/abandoned/
pending); BOOK/READINGLOG library; PREPSESSION interview practice.

Hunt for INCOHERENCE, in order of value:
1. Cross-table contradictions (a workout on a day whose checkin says rest; a
   plan on a trip-covered day; a lift session whose workout is a walk).
2. Rows that cannot describe reality (impossible times, dates, quantities,
   geographic impossibilities, journeys that outrun physics).
3. Data that will cause a FUTURE failure (windows, pending states, stale
   references) — say when it will bite.
4. Smells that suggest a bug minted them (clone patterns, sentinel values,
   titles that look machine-mangled).

Do NOT re-report what the deterministic audit already covers (it checks:
trip/stay/journey coverage, trip overlaps, duplicate stays, self-transitions,
implausible flight journeys, phantom arrivals, plans-under-trips, orphans,
corrupt event times, lift/run orphans, cloned workouts, stuck-live workouts,
duplicate reminders/todos/check-ins/plan-states/externalIDs, voice-note
basics, chat growth, plan-log liveness). Focus on what a fixed checklist
CANNOT see.

Then propose NEW deterministic invariants: precise, mechanically checkable
rules (table, columns, condition) that would have caught what you found or
that obviously should always hold. These get code-reviewed into the audit.

JSON ONLY:
{"score": 0-10,
 "findings": [{"severity":"high|medium|low","tables":["..."],
               "issue":"...","evidence":"the exact rows/values","willBite":"when/how"}],
 "proposedInvariants": [{"name":"kebab-case","rule":"precise condition over tables/columns",
                          "rationale":"..."}],
 "summary": "2-3 sentences"}"""


def main() -> None:
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        sys.exit("Set OPENAI_API_KEY in the environment.")
    if len(sys.argv) < 2:
        sys.exit("Usage: coherence-eval.py <dump.json>")
    path = Path(sys.argv[1])
    dump = path.read_text()

    payload = {
        "model": "gpt-5.6-terra",
        "messages": [{"role": "system", "content": RUBRIC},
                     {"role": "user", "content": dump}],
        "response_format": {"type": "json_object"},
        "max_completion_tokens": 12000,
    }
    req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            verdict = json.loads(json.load(r)["choices"][0]["message"]["content"])
    except urllib.error.HTTPError:
        payload["model"] = "gpt-5.6-terra"
        req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
            "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=600) as r:
            verdict = json.loads(json.load(r)["choices"][0]["message"]["content"])

    out = path.with_suffix(".coherence.json")
    out.write_text(json.dumps(verdict, indent=2))

    print(f"\nCoherence score: {verdict.get('score')}/10")
    print(f"{verdict.get('summary', '')}\n")
    order = {"high": 0, "medium": 1, "low": 2}
    for f in sorted(verdict.get("findings", []), key=lambda x: order.get(x.get("severity"), 3)):
        print(f"[{f.get('severity','?').upper():6}] {'/'.join(f.get('tables', []))}: {f.get('issue','')}")
        print(f"         evidence: {f.get('evidence','')[:160]}")
        if f.get("willBite"):
            print(f"         bites: {f.get('willBite','')[:120]}")
    props = verdict.get("proposedInvariants", [])
    if props:
        print(f"\nProposed invariants ({len(props)}) — review, then add to store-audit.py:")
        for p in props:
            print(f"  • {p.get('name','')}: {p.get('rule','')}")
    print(f"\nFull verdict: {out}")


if __name__ == "__main__":
    main()
