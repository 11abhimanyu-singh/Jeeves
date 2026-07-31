#!/usr/bin/env python3
"""
Jeeves logs → trajectory artifact: package REAL device usage into the same
artifact shape TrajectoryTests exports, so the dual-judge panel
(trajectory-judge.py) and the same rubric run on real conversations — not
just scripted test runs.

Sources, all from one pulled store:
  transcript  — ZCHATTURN, split into sessions on 45-minute gaps
                (same rule as trajectory-audit.py / chat-eval.py)
  toolCalls   — ZAPPEVENT rows of kind toolCall, bucketed into sessions
  endState    — trips, stays, journeys, events as stored right now

Real logs carry no scripted expectations — the "expectations" list is empty
and judges grade against the universal rubric only; the user's intent is read
from their own messages. Sessions that predate the tool-call recorder are
marked toolRecords=false: absence of records is not absence of actions, and
judges must not raise fabrication findings for those sessions.

Usage:
    python3 tools/logs-to-artifact.py <default.store> <out.json> [--since "YYYY-MM-DD HH:MM"]
Then:
    ANTHROPIC_API_KEY=... OPENAI_API_KEY=... python3 tools/trajectory-judge.py <out.json>
"""
import datetime
import json
import sqlite3
import sys
from pathlib import Path

EPOCH = 978307200


def ts(v):
    if v is None or v < -60000000000:
        return None
    return datetime.datetime.fromtimestamp(v + EPOCH)


def pick(row, *names):
    """First present, non-None column among candidates — schema-name tolerant."""
    for n in names:
        if n in row.keys() and row[n] is not None:
            return row[n]
    return None


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    db = sqlite3.connect(sys.argv[1])
    db.row_factory = sqlite3.Row
    since = None
    if "--since" in sys.argv:
        since = datetime.datetime.strptime(sys.argv[sys.argv.index("--since") + 1],
                                           "%Y-%m-%d %H:%M")

    turns = [dict(t=ts(r["ZTIMESTAMP"]), role=r["ZROLERAW"], text=r["ZCONTENT"] or "")
             for r in db.execute("SELECT * FROM ZCHATTURN ORDER BY ZTIMESTAMP")]
    calls = [dict(t=ts(r["ZDATE"]), text=r["ZDETAIL"] or "")
             for r in db.execute("SELECT * FROM ZAPPEVENT WHERE ZKINDRAW='toolCall' ORDER BY ZDATE")]
    turns = [x for x in turns if x["t"] and (not since or x["t"] >= since)]
    calls = [x for x in calls if x["t"] and (not since or x["t"] >= since)]

    # Sessions split on 45-minute gaps — same rule as the deterministic audit.
    sessions = []
    for turn in turns:
        if sessions and (turn["t"] - sessions[-1][-1]["t"]).total_seconds() < 45 * 60:
            sessions[-1].append(turn)
        else:
            sessions.append([turn])

    transcript, tool_calls, no_records = [], [], []
    for si, session in enumerate(sessions):
        sid = f"session-{si}-{session[0]['t']:%Y-%m-%d-%H%M}"
        lo, hi = session[0]["t"], session[-1]["t"] + datetime.timedelta(minutes=2)
        sess_calls = [c for c in calls if lo <= c["t"] <= hi]
        if not sess_calls:
            no_records.append(sid)
        for turn in session:
            transcript.append({"dialogue": sid, "role": turn["role"],
                               "text": turn["text"], "at": f"{turn['t']:%Y-%m-%d %H:%M}"})
        for c in sess_calls:
            # ZDETAIL is "<name>(<digest>) → <result>" — keep the whole line
            # (judges read it raw); split on "(" for the clean tool name so it
            # matches the TrajectoryTests artifact's name field.
            name = (c["text"].split("(", 1)[0] if c["text"] else "?")
            tool_calls.append({"dialogue": sid, "name": name, "input": "",
                               "result": c["text"][:400], "at": f"{c['t']:%Y-%m-%d %H:%M}"})

    def rows(table):
        try:
            return list(db.execute(f"SELECT * FROM {table}"))
        except sqlite3.OperationalError:
            return []

    def d(v):
        t = ts(v)
        return f"{t:%Y-%m-%d %H:%M}" if t else "?"

    end_state = {
        "trips": [f"{r['ZTITLE'] or ''} {d(r['ZSTARTDATE'])} → {d(r['ZENDDATE'])}"
                  for r in rows("ZTRIP")],
        "stays": [f"{pick(r, 'ZPLACE', 'ZNAME') or ''} "
                  f"{d(pick(r, 'ZARRIVEDATE', 'ZARRIVE'))} → {d(pick(r, 'ZDEPARTDATE', 'ZDEPART'))}"
                  for r in rows("ZTRIPSTAY")],
        "journeys": [f"[{r['ZMODERAW'] or '?'}] {r['ZLABEL'] or ''} "
                     f"travel={pick(r, 'ZTRAVELMINUTES', 'ZTRAVELTIME') or '?'}"
                     for r in rows("ZTRAVELSEGMENT")],
        "events": [f"{r['ZTITLE'] or ''} {d(r['ZDATE'])} "
                   f"{pick(r, 'ZSTARTMINUTE') or 0}-{pick(r, 'ZENDMINUTE') or 0}"
                   for r in rows("ZDAILYEVENT")],
    }

    artifact = {
        "source": "device-logs",
        "caveats": ("Real usage, not a scripted test. No per-scenario expectations — "
                    "judge against the universal rubric; the user's intent is their own "
                    "messages. Sessions listed in sessionsWithoutToolRecords predate the "
                    "tool-call recorder: for those, absence of a recorded call is NOT "
                    "evidence of fabrication."),
        "sessionsWithoutToolRecords": no_records,
        "transcript": transcript,
        "toolCalls": tool_calls,
        "endState": end_state,
        "failures": [],
        "expectations": [],
    }
    out = Path(sys.argv[2])
    out.write_text(json.dumps(artifact, indent=2))
    print(f"{len(sessions)} session(s), {len(tool_calls)} tool call(s), "
          f"{len(no_records)} session(s) without tool records")
    print(f"artifact: {out}")
    print(f"next: python3 tools/trajectory-judge.py {out}")


if __name__ == "__main__":
    main()
