#!/usr/bin/env python3
"""
Jeeves UX eval: GPT audits a user-journey walkthrough.

Input is a faithful step-by-step walkthrough of what the CURRENT build does for
one scenario (reconstructed from the shipped code — fields, defaults, dead
ends), so the judge audits reality rather than a mockup. Output is scored
friction points and concrete fixes, ranked.

Usage:
    OPENAI_API_KEY=sk-... python3 tools/ux-eval.py <walkthrough.md>
Writes <walkthrough>-verdict.json beside the input.
The key is read from the environment only — never stored.
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

API = "https://api.openai.com/v1/chat/completions"

RUBRIC = """You are a senior product designer auditing a personal iOS planner
("Jeeves", single user, warm-editorial design). You are given a faithful
walkthrough of what the CURRENT build does for one scenario — every field,
default and outcome described actually happens.

Audit the experience end to end:
- Where does the user do work the app already had the data for?
- Where do defaults actively mislead (worse than empty)?
- Where does correct data become invisible or silently wrong?
- Which single change most improves this scenario?

Judge severity by consequence for THIS app's stakes (missed flights, wasted
mornings), not by UI polish. Do not invent behavior beyond the walkthrough.

JSON ONLY:
{"score": 0-10,
 "findings": [{"severity":"high|medium|low","step":"...","issue":"...","fix":"..."}],
 "theOneChange": "the single highest-leverage fix, one sentence",
 "summary": "2-3 sentences"}"""


def main() -> None:
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        sys.exit("Set OPENAI_API_KEY in the environment.")
    if len(sys.argv) < 2:
        sys.exit("Usage: ux-eval.py <walkthrough.md>")
    path = Path(sys.argv[1])
    walkthrough = path.read_text()

    payload = {
        "model": "gpt-5.6-terra",
        "messages": [{"role": "system", "content": RUBRIC},
                     {"role": "user", "content": walkthrough}],
        "response_format": {"type": "json_object"},
        "max_completion_tokens": 6000,
    }
    req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            verdict = json.loads(json.load(r)["choices"][0]["message"]["content"])
    except urllib.error.HTTPError:
        payload["model"] = "gpt-5.6-terra"
        req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
            "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=300) as r:
            verdict = json.loads(json.load(r)["choices"][0]["message"]["content"])

    out = path.with_suffix(".verdict.json")
    out.write_text(json.dumps(verdict, indent=2))

    print(f"\nUX score: {verdict.get('score')}/10")
    print(f"{verdict.get('summary', '')}\n")
    order = {"high": 0, "medium": 1, "low": 2}
    for f in sorted(verdict.get("findings", []), key=lambda x: order.get(x.get("severity"), 3)):
        print(f"[{f.get('severity','?').upper():6}] {f.get('step','')}: {f.get('issue','')}")
        print(f"         fix: {f.get('fix','')}")
    print(f"\n⭐ The one change: {verdict.get('theOneChange', '')}")
    print(f"\nFull verdict: {out}")


if __name__ == "__main__":
    main()
