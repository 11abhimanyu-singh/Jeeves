#!/usr/bin/env python3
"""
Jeeves plan eval: GPT judges the REAL generated day plans.

The in-app judge (OpenAIJudgeService) scores plans built from synthetic
scenarios; this one scores what the planner actually produced for real days,
against the day's real context — events (with venues and all-day flags), gym
state, and whether the day is covered by a Trip (travel mode).

Reads plans.json (produced by extracting DailyPlanState + context from the
store) and writes plan-eval.json next to it.

Usage:
    OPENAI_API_KEY=sk-... python3 tools/plan-eval.py <data-dir> [YYYY-MM-DD ...]
Dates limit which plans are judged; omit to judge them all.
The key is read from the environment only — never stored.
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

API = "https://api.openai.com/v1/chat/completions"

RUBRIC = """You are auditing day plans produced by "Jeeves", a personal iOS planner.
House rules the planner is supposed to honour:
- Fixed events are immovable anchors; commute legs must precede/follow them with
  realistic durations for the stated venue (a 265 km lodge is ~6 h, not 30 min).
- Lunch in a sensible midday window; sleep 23:00–07:00; gym (when set) is one
  contiguous session at its stated time, ~70 minutes of lifting.
- All-day events have no times and must never appear as 00:00–00:00 blocks.
- Days covered by a TRIP (travelModeTrips non-empty) are travel days: the
  planner is supposed to STAND DOWN there — a routine-filled plan on such a day
  is stale output that predates travel mode, and its existence is itself a
  finding (severity depends on how misleading the content is).
- A plan should fill the waking day without gaps or overlaps.

For the given day, judge the stored plan against its context. Score 0-10.
Report concrete violations (times + block names), whether the plan is STALE
relative to travel mode, and up to 3 improvements. JSON ONLY:
{"date":"...","score":0-10,"stale":true|false,"violations":["..."],
 "improvements":["..."],"summary":"1-2 sentences"}"""


def call_gpt(key: str, model: str, content: str) -> dict:
    payload = {
        "model": model,
        "messages": [{"role": "system", "content": RUBRIC},
                     {"role": "user", "content": content}],
        "response_format": {"type": "json_object"},
        "max_completion_tokens": 4000,
    }
    req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(json.load(r)["choices"][0]["message"]["content"])


def main() -> None:
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        sys.exit("Set OPENAI_API_KEY in the environment.")
    if len(sys.argv) < 2:
        sys.exit("Usage: plan-eval.py <data-dir> [dates...]")
    data_dir = Path(sys.argv[1])
    wanted = set(sys.argv[2:])
    plans = json.loads((data_dir / "plans.json").read_text())
    if wanted:
        plans = [p for p in plans if p["date"] in wanted]
    if not plans:
        sys.exit("No plans matched.")

    reports = []
    for p in plans:
        content = json.dumps({
            "date": p["date"],
            "travelModeTrips": p.get("travelModeTrips", []),
            "gym": {"set": p.get("gym"), "minuteOfDay": p.get("gymMinute")},
            "generatedOffline": p.get("offline"),
            "events": p.get("events", []),
            "planBlocks": p["plan"].get("blocks", []),
        }, indent=1)
        try:
            verdict = call_gpt(key, "gpt-5.6-terra", content)
        except Exception:
            verdict = call_gpt(key, "gpt-5.6-terra", content)
        reports.append(verdict)
        flag = "🧳" if verdict.get("stale") else ("⚠️" if verdict.get("score", 10) < 7 else "  ")
        print(f"\n{flag} {p['date']} — score {verdict.get('score')}/10"
              + (" · STALE (travel day)" if verdict.get("stale") else ""))
        print(f"   {verdict.get('summary', '')}")
        for v in verdict.get("violations", []):
            print(f"   ✗ {v}")
        for imp in verdict.get("improvements", [])[:3]:
            print(f"   → {imp}")

    out = data_dir / "plan-eval.json"
    out.write_text(json.dumps({"plans": reports}, indent=2))
    print(f"\nFull report: {out}")


if __name__ == "__main__":
    main()
