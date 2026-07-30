#!/usr/bin/env python3
"""
Jeeves trajectory audit: does the story the assistant told match the state
it left behind?

Every chat tool call is recorded in the AppEvent log (kind toolCall, with an
input + result digest), so EVERY conversation is a trajectory artifact:
transcript (ZCHATTURN) + tool calls (ZAPPEVENT) + final state — all in the
same pulled store. This runs the deterministic assertions over a session:

  1. NO HEAD-MATH — every clock time (HH:MM am/pm) the assistant quotes in a
     turn that follows tool activity must appear in some tool result of the
     session. The "leave falls by 3:25 PM" narration, stored nowhere, fails
     here.
  2. NO DUPLICATE LEGS — at session end, no trip holds two journeys with the
     same mode + label + anchor day (the four-outbound-drives fossil record).
  3. NO DUPLICATE TRIPS — no two trips share a title and overlapping days.
  4. CLAIMED ACTIONS HAPPENED — a turn containing "deleted"/"removed" must be
     preceded by a delete-ish tool call in the same session.
  5. NO UNANSWERED TURNS — every user turn gets an assistant turn before the
     next user turn or within 5 minutes; the user answering "20" into twelve
     minutes of silence is a failure whatever caused it. (Runs on all
     sessions — silence needs no tool records to be provable.)
  6. NO SELF-DATE CONFUSION — the assistant calling the current date
     "yesterday"/"tomorrow" in a recap.

Usage:
    python3 tools/trajectory-audit.py <default.store> [--since "YYYY-MM-DD HH:MM"]
Sessions are split on 45-minute gaps, matching chat-eval. Exit 1 on failures.
"""
import datetime
import re
import sqlite3
import sys
from pathlib import Path

EPOCH = 978307200
TIME_RE = re.compile(r"\b(\d{1,2}):(\d{2})\s*(am|pm|AM|PM)?\b")
DELETE_CLAIM_RE = re.compile(r"\b(deleted|removed|gone from)\b", re.IGNORECASE)
DELETE_TOOLS = ("delete_event", "delete_todo", "delete_reminder", "delete_trip",
                "delete_journey", "clean_travel_data")


def ts(v):
    if v is None or v < -60000000000:
        return None
    return datetime.datetime.fromtimestamp(v + EPOCH)


def norm_time(h, m, ampm):
    h = int(h) % 24
    if ampm and ampm.lower() == "pm" and h < 12:
        h += 12
    if ampm and ampm.lower() == "am" and h == 12:
        h = 0
    return f"{h:02}:{m}"


def times_in(text):
    return {norm_time(h, m, ap) for h, m, ap in TIME_RE.findall(text or "")}


def main():
    if len(sys.argv) < 2:
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

    # Sessions split on 45-minute gaps.
    sessions = []
    for turn in turns:
        if sessions and (turn["t"] - sessions[-1][-1]["t"]).total_seconds() < 45 * 60:
            sessions[-1].append(turn)
        else:
            sessions.append([turn])

    failures = []
    # Unanswered turns + self-date confusion need no tool records — they run
    # on every session, including pre-recorder history.
    for si, session in enumerate(sessions):
        for i, turn in enumerate(session):
            if turn["role"] != "user":
                continue
            nxt = session[i + 1] if i + 1 < len(session) else None
            if nxt is None:
                continue  # last turn of session; the user may just have left
            if nxt["role"] == "user":
                gap = (nxt["t"] - turn["t"]).total_seconds() / 60
                if gap > 5:
                    failures.append((si, "unanswered-turn",
                                     f"user said \"{turn['text'][:40]}\" at {turn['t']:%H:%M} — no reply for {gap:.0f} min until their next message"))
        for turn in session:
            if turn["role"] == "assistant":
                today_str = turn["t"].strftime("%B %-d").lower()
                low = (turn["text"] or "").lower()
                if "yesterday" in low and today_str in low:
                    failures.append((si, "self-date-confusion",
                                     f"turn {turn['t']:%H:%M} calls today ({today_str}) 'yesterday'"))
    for si, session in enumerate(sessions):
        lo, hi = session[0]["t"], session[-1]["t"] + datetime.timedelta(minutes=2)
        sess_calls = [c for c in calls if lo <= c["t"] <= hi]
        if not sess_calls:
            # Sessions predating the tool-call recorder can't be judged on
            # their claims — absence of records is not absence of actions.
            continue
        tool_text = " ".join(c["text"] for c in sess_calls)
        tool_times = times_in(tool_text)

        for turn in session:
            if turn["role"] != "assistant":
                continue
            preceding = [c for c in sess_calls if c["t"] <= turn["t"] + datetime.timedelta(minutes=1)]
            if preceding:
                quoted = times_in(turn["text"])
                # Only times plausibly ABOUT the plan (skip when no tools ran).
                ghost = quoted - tool_times
                if ghost and len(quoted) > 0:
                    failures.append((si, "head-math",
                                     f"assistant quoted {sorted(ghost)} — absent from every tool result"
                                     f" (turn {turn['t']:%H:%M}: \"{turn['text'][:90]}…\")"))
            if DELETE_CLAIM_RE.search(turn["text"]):
                had_delete = any(c["text"].startswith(DELETE_TOOLS) and c["t"] <= turn["t"]
                                 for c in sess_calls)
                if not had_delete:
                    failures.append((si, "claimed-action",
                                     f"turn {turn['t']:%H:%M} claims a deletion but no delete tool ran"
                                     f" (\"{turn['text'][:90]}…\")"))

    # End-state duplicate checks (whole store, no date limit).
    segs = [dict(trip=r["ZTRIPID"], mode=r["ZMODERAW"], label=(r["ZLABEL"] or "").lower(),
                 anchor=ts(r["ZARRIVEBY"]) or ts(r["ZDEPARTAT"]))
            for r in db.execute("SELECT * FROM ZTRAVELSEGMENT")]
    seen = {}
    for s in segs:
        key = (bytes(s["trip"] or b""), s["mode"], s["label"],
               s["anchor"].date() if s["anchor"] else None)
        if key in seen:
            failures.append((-1, "duplicate-leg",
                             f"two '{s['label'] or s['mode']}' journeys on {key[3]} in one trip"))
        seen[key] = True
    trips = [dict(title=(r["ZTITLE"] or "").lower(), s=ts(r["ZSTARTDATE"]), e=ts(r["ZENDDATE"]))
             for r in db.execute("SELECT * FROM ZTRIP")]
    for i, a in enumerate(trips):
        for b in trips[i + 1:]:
            if (a["title"] and a["title"] == b["title"] and a["s"] and b["s"]
                    and a["e"] >= b["s"] and b["e"] >= a["s"]):
                failures.append((-1, "duplicate-trip",
                                 f"two '{a['title']}' trips overlap ({a['s']:%d %b}–{a['e']:%d %b})"))

    print(f"{len(sessions)} session(s), {len(calls)} recorded tool call(s)")
    if not failures:
        print("CLEAN — every story matches the state.")
        sys.exit(0)
    for si, rule, msg in failures:
        where = f"session {si}" if si >= 0 else "end-state"
        print(f"[FAIL] {where} · {rule}: {msg}")
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1)


if __name__ == "__main__":
    main()
