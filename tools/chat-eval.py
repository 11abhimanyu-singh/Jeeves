#!/usr/bin/env python3
"""
Jeeves chat eval: GPT judges each conversation for correctness and quality.

Reads chat turns (from state-latest.json, or a data dir holding chat.json
pulled off the device) plus a ground-truth snapshot of the app's data, groups
turns into sessions, and asks GPT to judge every assistant reply:
  - factually correct against the ground truth?
  - intent completed, or did the user give up / hit a capability gap?
  - repetition, unnecessary questions, bluffing about data it didn't fetch
  - concrete improvement suggestions (prompt rules or missing tools)

Usage:
    OPENAI_API_KEY=sk-... python3 tools/chat-eval.py [data-dir]
Writes chat-eval.json into the data dir and prints the findings.
The key is read from the environment only — never stored.
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

DATA_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else (
    Path.home() / "Library/Mobile Documents/iCloud~abhimanyusingh~me~Jeeves/Documents")
OUT = DATA_DIR / "chat-eval.json"
API = "https://api.openai.com/v1/chat/completions"
SESSION_GAP_MIN = 45

RUBRIC = """You are auditing "Jeeves", a personal iOS day-planning assistant with tool access:
add_event, edit_event, delete_event, set_gym, fetch_calendar, plan_day, replan_today,
commute_estimate (live-traffic leave-by times), fetch_app_data (events/lifts/workouts/
runs/run_program/todos/reminders/checkins/books), add_todo, complete_todo, delete_todo,
add_reminder, delete_reminder, log_walk, mark_block_done, fetch_chat_history,
remember_preference (standing rules, optionally time-bounded via an expires date).
NOTE: tools were added over time — in OLDER transcript turns a capability may genuinely
not have existed yet; judge each turn against what the reply itself claims, and flag as
'stale-limitation' any turn where the assistant denies a capability the list above has.
The user speaks Indian English; messages may arrive via voice transcription with errors.

You are given (1) GROUND TRUTH: a snapshot of the user's actual app data, and
(2) a chat session transcript. Judge every assistant reply:
- correctness: does each factual claim match the ground truth? (e.g. a stated max
  lift weight, "no walks logged", event dates). Mark wrong claims explicitly.
- data use: did it appear to consult the right collection, or answer from the wrong
  one / from memory? (e.g. answering "longest walk" from runs only, when walks live
  in the workouts collection.)
- intent: did the user get what they asked for? If they hit a missing capability,
  name the tool that would have fixed it.
- conduct: repetition, re-offering declined things, unnecessary questions, over-long
  replies, bluffing.
Score the session 0-10 and list concrete improvements (prompt rules or new tools).

Respond with JSON ONLY:
{"score": 0-10, "verdicts": [{"assistantReplyAt": "HH:MM", "correct": true|false|"unverifiable",
 "issue": "...", "evidence": "..."}], "capabilityGaps": ["..."],
 "improvements": ["..."], "summary": "2-3 sentences"}

STORY VS STATE — the highest-severity check: cross-reference EVERY claim the
assistant makes (numbers, times, "deleted", "added", "updated") against the
ground-truth state you were given. A reply that narrates an outcome the state
does not show (a deletion that left rows behind, a leave-by time no tool
computed, an assumption promised but absent from the store) is a FABRICATION
finding, severity high, regardless of how helpful the tone was."""


def call_gpt(key: str, model: str, content: str) -> dict:
    payload = {
        "model": model,
        "messages": [{"role": "system", "content": RUBRIC},
                     {"role": "user", "content": content}],
        "response_format": {"type": "json_object"},
        "max_completion_tokens": 8000,
    }
    req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(json.load(r)["choices"][0]["message"]["content"])


def load_turns() -> list[dict]:
    local = DATA_DIR / "chat.json"
    if local.exists():
        return json.loads(local.read_text())
    state = DATA_DIR / "state-latest.json"
    rows = json.loads(state.read_text()).get("chatTurns", [])
    return [{"ts": r["timestamp"], "role": r["role"], "content": r["content"],
             "isPlan": r.get("isPlan", False)} for r in rows]


def parse_ts(raw: str):
    """The app exports IST-labelled stamps ('2026-07-28 12:21:23 IST'); a
    cable pull yields plain SQL datetimes. Accept both (and ISO 'T')."""
    from datetime import datetime
    cleaned = raw.strip()
    for suffix in (" IST", "Z"):
        if cleaned.endswith(suffix):
            cleaned = cleaned[: -len(suffix)].strip()
    try:
        return datetime.fromisoformat(cleaned)
    except ValueError:
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M"):
            try:
                return datetime.strptime(cleaned[:19], fmt)
            except ValueError:
                continue
        raise


def ground_truth() -> str:
    """What the judge checks the assistant's claims against. Prefers an
    explicit ground-truth.json, else derives one from the app's own export
    (state-latest.json). Judging with NO ground truth produces phantom
    findings, so say so loudly rather than silently passing '{}'."""
    explicit = DATA_DIR / "ground-truth.json"
    if explicit.exists():
        return explicit.read_text()
    state = DATA_DIR / "state-latest.json"
    if state.exists():
        s = json.loads(state.read_text())
        derived = {k: s.get(k, []) for k in
                   ("events", "workouts", "lifts", "runs", "todos", "reminders",
                    "checkIns", "plans", "voiceNotes")}
        if any(derived.values()):
            print(f"ground truth derived from {state.name} "
                  f"({sum(len(v) for v in derived.values())} records)")
            return json.dumps(derived, indent=1)
    print("WARNING: no ground truth — correctness verdicts will be unreliable.")
    return "{}"


def sessions(turns: list[dict]) -> list[list[dict]]:
    """Split on >45-minute gaps (same window as the app's session)."""
    out, cur, prev = [], [], None
    for t in turns:
        ts = parse_ts(t["ts"])
        if prev and (ts - prev).total_seconds() > SESSION_GAP_MIN * 60 and cur:
            out.append(cur)
            cur = []
        cur.append(t)
        prev = ts
    if cur:
        out.append(cur)
    return out


def main() -> None:
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        sys.exit("Set OPENAI_API_KEY in the environment (never store it in the repo).")
    turns = load_turns()
    if not turns:
        print("No chat turns found.")
        return
    truth = ground_truth()

    reports = []
    for i, sess in enumerate(sessions(turns), 1):
        lines = "\n".join(
            f"[{t['ts'][11:16]}] {'USER' if t['role'] == 'user' else 'JEEVES'}: "
            f"{t['content'] or ('[plan card]' if t.get('isPlan') else '[empty]')}"
            for t in sess)
        content = f"GROUND TRUTH:\n{truth}\n\nSESSION {i} TRANSCRIPT:\n{lines}"
        try:
            verdict = call_gpt(key, "gpt-5.6-terra", content)
        except Exception:
            # Single same-model RETRY for transient failures (no older-model
            # fallback exists any more).
            verdict = call_gpt(key, "gpt-5.6-terra", content)
        verdict["session"] = i
        verdict["turns"] = len(sess)
        reports.append(verdict)
        print(f"\n━━ Session {i} ({len(sess)} turns) — score {verdict.get('score')}/10")
        print(f"   {verdict.get('summary', '')}")
        for v in verdict.get("verdicts", []):
            if v.get("correct") is False:
                print(f"   ✗ [{v.get('assistantReplyAt')}] {v.get('issue')}")
        for g in verdict.get("capabilityGaps", []):
            print(f"   ⚒ gap: {g}")
        for imp in verdict.get("improvements", []):
            print(f"   → {imp}")

    OUT.write_text(json.dumps({"sessions": reports}, indent=2))
    print(f"\nFull report: {OUT}")


if __name__ == "__main__":
    main()
