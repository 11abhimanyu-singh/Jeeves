#!/usr/bin/env python3
"""
Extract the requirement register from what the USER actually said.

THE PROBLEM THIS SOLVES

Requirements live in three places: docs/PRD.md, the approved plan files, and
several thousand chat messages. Claude summarising those into a checklist puts
Claude back in the loop — and Claude dropping a requirement is the exact failure
this whole harness exists to catch. (The -/+ 15-minute duration control was in
an approved plan, and shipped missing.)

So GPT reads the same sources independently and writes its own register. Anything
only one of the two registers contains is flagged by tools/spec-diff.py.

Corpus: `type == "user"` entries in the Claude Code transcripts — the user's own
words, verbatim, with no summarisation step in between.

Usage:
    OPENAI_API_KEY=sk-... python3 tools/spec-extract.py [--days N] [--all]
Writes docs/SPEC.gpt.md and docs/.spec-watermark.json.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

API = "https://api.openai.com/v1/chat/completions"
MODEL = "gpt-5.6-terra"
REPO = Path(__file__).resolve().parent.parent
TRANSCRIPTS = os.path.expanduser("~/.claude/projects/-Users-abhimanyusingh-*/*.jsonl")
SKIP = ("<system-reminder", "[Request interrupted", "Caveat:", "<command-name>")

MAP_PROMPT = """You are reading a slice of chat between a user and an engineer,
about a single-user iOS planner app called Jeeves. ONLY the user's messages are
shown, in order.

Extract every REQUIREMENT the user stated: something the app must do, must stop
doing, or must look like. Include requirements stated as complaints ("the gym
toggle doesn't work"), as corrections ("no, it should land in chat first"), and
as specifications pasted wholesale.

Rules:
- A requirement is testable by looking at the app. "Make it nicer" is not one;
  "add a delete icon per activity" is.
- Preserve the user's own wording in `statement`. Do not smooth it out.
- If a later message CHANGES an earlier requirement, emit only the later one and
  set `supersedes` to the earlier statement.
- Ignore chatter, thanks, and questions that ask for information.

JSON ONLY:
{"requirements": [{"statement": "...", "area": "planner|chat|notifications|fitness|library|travel|tasks|settings|other",
                   "supersedes": "" }]}"""

REDUCE_PROMPT = """You are merging several lists of requirements for one iOS app
into a single register.

- Merge duplicates and near-duplicates into one entry, keeping the clearest wording.
- Where one entry supersedes another, keep only the surviving requirement.
- Give each a stable id: the area in caps, a dash, and a two-digit number
  (PLANNER-01, CHAT-07 …). Number within an area in the order given.
- Drop anything not checkable by looking at the running app.

JSON ONLY:
{"requirements": [{"id":"AREA-NN","statement":"...","area":"...","note":""}]}"""


def keychain(service: str) -> str:
    try:
        return subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except Exception:                                  # noqa: BLE001
        return ""


def user_messages(since: datetime | None) -> list[tuple[str, str]]:
    """(timestamp, text) for every real user message, oldest first."""
    out = []
    for path in sorted(glob.glob(TRANSCRIPTS)):
        with open(path, errors="replace") as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("type") != "user":
                    continue
                content = entry.get("message", {}).get("content")
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    # Tool RESULTS also arrive as user entries; only text blocks
                    # are things the human typed.
                    text = "".join(b.get("text", "") for b in content
                                   if isinstance(b, dict) and b.get("type") == "text")
                else:
                    continue
                text = text.strip()
                if not text or text.startswith(SKIP):
                    continue
                stamp = entry.get("timestamp", "")
                if since and stamp:
                    try:
                        if datetime.fromisoformat(stamp.replace("Z", "+00:00")) < since:
                            continue
                    except ValueError:
                        pass
                out.append((stamp, text))
    out.sort(key=lambda r: r[0])
    return out


def call_gpt(key: str, system: str, user: str) -> dict:
    payload = {"model": MODEL,
               "messages": [{"role": "system", "content": system},
                            {"role": "user", "content": user}],
               "response_format": {"type": "json_object"},
               "max_completion_tokens": 16000}
    req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        body = json.loads(resp.read())
    return json.loads(body["choices"][0]["message"]["content"])


def chunks(messages: list[tuple[str, str]], size: int = 200_000):
    """~50k tokens per chunk, split on message boundaries."""
    buf, used = [], 0
    for stamp, text in messages:
        piece = f"[{stamp}] {text}\n\n"
        if used + len(piece) > size and buf:
            yield "".join(buf)
            buf, used = [], 0
        buf.append(piece)
        used += len(piece)
    if buf:
        yield "".join(buf)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7,
                        help="how far back to read (default 7; the register is "
                             "cumulative, so old runs are not re-read)")
    parser.add_argument("--all", action="store_true", help="read the whole corpus")
    args = parser.parse_args()

    key = os.environ.get("OPENAI_API_KEY", "").strip() or keychain("jeeves-openai")
    if not key:
        sys.exit("Set OPENAI_API_KEY, or store it in the Keychain as 'jeeves-openai'.")

    since = None if args.all else datetime.now(timezone.utc) - timedelta(days=args.days)
    messages = user_messages(since)
    if not messages:
        sys.exit("No user messages in range.")
    print(f"{len(messages)} user messages, {sum(len(t) for _, t in messages):,} chars")

    found: list[dict] = []
    for index, chunk in enumerate(chunks(messages), 1):
        print(f"  chunk {index} ({len(chunk):,} chars) …", flush=True)
        try:
            found += call_gpt(key, MAP_PROMPT, chunk).get("requirements", [])
        except Exception as exc:                       # noqa: BLE001
            # Loud, not silent: a dropped chunk is a hole in the register.
            print(f"  chunk {index} FAILED: {exc}", file=sys.stderr)
    print(f"  {len(found)} raw requirements → reducing")

    register = call_gpt(key, REDUCE_PROMPT,
                        json.dumps({"lists": found}, indent=1)).get("requirements", [])

    lines = ["# Requirement register (extracted by GPT from the user's own messages)",
             "",
             f"<!-- {len(register)} requirements from {len(messages)} user messages;",
             f"     generated by tools/spec-extract.py, do not hand-edit -->",
             ""]
    for area in sorted({r.get("area", "other") for r in register}):
        lines.append(f"## {area}")
        lines.append("")
        for r in [x for x in register if x.get("area", "other") == area]:
            lines.append(f'- **{r["id"]}** — {r["statement"]}')
        lines.append("")
    (REPO / "docs" / "SPEC.gpt.md").write_text("\n".join(lines))
    (REPO / "docs" / ".spec-watermark.json").write_text(
        json.dumps({"lastMessage": messages[-1][0], "count": len(register)}, indent=2))
    print(f"{len(register)} requirements → docs/SPEC.gpt.md")


if __name__ == "__main__":
    main()
