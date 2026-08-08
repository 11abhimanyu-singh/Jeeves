#!/usr/bin/env python3
"""
Merge the two requirement registers and flag whatever only one of them found.

WHY TWO REGISTERS

docs/SPEC.claude.md is written by the same author who builds the app. A register
written by that author inherits that author's blind spots — which is not a
hypothetical: the -/+ 15-minute duration control was in an approved plan and
shipped missing, and a Claude-authored checklist would have been just as likely
to omit it.

docs/SPEC.gpt.md is extracted by GPT straight from the user's own messages
(tools/spec-extract.py). Neither register is trusted alone. Anything present in
one and absent from the other is marked ONE-SIDED in the merged file, which is
the signal to go and look.

Matching is by meaning, not string equality, so this needs the model too.

Usage:
    OPENAI_API_KEY=sk-... python3 tools/spec-diff.py
Writes docs/SPEC.md — the register tools/screen-judge.py grades against.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

API = "https://api.openai.com/v1/chat/completions"
MODEL = "gpt-5.6-terra"
REPO = Path(__file__).resolve().parent.parent
ENTRY = re.compile(r"^- \*\*([A-Z-]+\d+)\*\* — (.+)$")
DECISION = re.compile(r"^## ([A-Z-]+\d+)\s*$")

PROMPT = """You are merging two independently written requirement registers for
the same iOS app. One was written by the engineer who builds it; the other was
extracted from the user's own chat messages.

Pair up requirements that mean the SAME THING even when they are worded
differently ("adjust each duration in 15-minute increments" and "each row's
duration can be adjusted in 15-minute steps" are one requirement, not two).

For each requirement in the merged register set `sources`:
  "both"   — both registers contain it
  "claude" — only the engineer's register (the user may never have asked for it,
             or GPT missed it)
  "gpt"    — only the extraction from the user's messages. THESE MATTER MOST:
             the user asked and the engineer's own list does not have it.

Keep the id from whichever register has one; prefer the "both" side's wording.
Do not invent requirements that are in neither list.

JSON ONLY:
{"requirements":[{"id":"...","statement":"...","area":"...","sources":"both|claude|gpt"}]}"""


def keychain(service: str) -> str:
    try:
        return subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except Exception:                                  # noqa: BLE001
        return ""


def parse(path: Path) -> list[dict]:
    out, area = [], "other"
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        if line.startswith("## "):
            area = line[3:].strip()
        match = ENTRY.match(line.strip())
        if match:
            out.append({"id": match[1], "statement": match[2], "area": area})
    return out


def decisions(path: Path) -> dict[str, str]:
    """User adjudications, by requirement id.

    The extraction re-reads the transcripts every run and will keep producing its
    original wording, so a disagreement about what a requirement MEANS has to be
    settled somewhere durable. Settled by the USER — quietly rewriting a
    requirement to match what was built is precisely what two registers exist to
    prevent, and it would be indistinguishable from getting away with it.
    """
    if not path.exists():
        return {}
    out, current, body = {}, None, []
    for line in path.read_text().splitlines():
        match = DECISION.match(line.strip())
        if match:
            if current and body:
                out[current] = " ".join(body).strip()
            current, body = match[1], []
            continue
        if current and line.strip().startswith("**Statement:**"):
            body = [line.split("**Statement:**", 1)[1].strip()]
        elif current and body and line.strip() and not line.startswith("**"):
            body.append(line.strip())
        elif current and body and (not line.strip() or line.startswith("**")):
            out[current] = " ".join(body).strip()
            body = []
    if current and body:
        out[current] = " ".join(body).strip()
    return out


def uniquify(reqs: list[dict]) -> list[dict]:
    """Two registers can independently mint CHAT-01, and the merge kept both —
    so the report showed the same id as present AND absent on adjacent lines."""
    seen: dict[str, int] = {}
    for r in reqs:
        rid = r.get("id", "REQ")
        if rid in seen:
            seen[rid] += 1
            r["id"] = f"{rid}{chr(ord('a') + seen[rid] - 1)}"
        else:
            seen[rid] = 1
    return reqs


def main() -> None:
    key = os.environ.get("OPENAI_API_KEY", "").strip() or keychain("jeeves-openai")
    if not key:
        sys.exit("Set OPENAI_API_KEY, or store it in the Keychain as 'jeeves-openai'.")

    mine = parse(REPO / "docs" / "SPEC.claude.md")
    theirs = parse(REPO / "docs" / "SPEC.gpt.md")
    if not mine or not theirs:
        sys.exit("Need both docs/SPEC.claude.md and docs/SPEC.gpt.md "
                 "(run tools/spec-extract.py first).")
    print(f"claude: {len(mine)} · gpt: {len(theirs)}")

    payload = {"model": MODEL,
               "messages": [{"role": "system", "content": PROMPT},
                            {"role": "user", "content": json.dumps(
                                {"claudeRegister": mine, "gptRegister": theirs}, indent=1)}],
               "response_format": {"type": "json_object"},
               "max_completion_tokens": 16000}
    req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        merged = json.loads(json.loads(resp.read())["choices"][0]["message"]["content"])

    reqs = uniquify(merged.get("requirements", []))
    settled = decisions(REPO / "docs" / "SPEC.decisions.md")
    for r in reqs:
        # Match on the base id too, so a collision-suffixed CHAT-01a still
        # receives the adjudication written against CHAT-01.
        base = re.sub(r"([a-z])$", "", r.get("id", ""))
        if statement := (settled.get(r.get("id", "")) or settled.get(base)):
            r["statement"] = statement
            r["clarified"] = True
    only_gpt = [r for r in reqs if r.get("sources") == "gpt"]
    only_claude = [r for r in reqs if r.get("sources") == "claude"]

    lines = ["# Requirement register (merged)",
             "",
             "<!-- generated by tools/spec-diff.py from SPEC.claude.md + SPEC.gpt.md;",
             "     do not hand-edit. ONE-SIDED entries are the ones to look at. -->",
             "",
             f"- {len(reqs)} requirements · {len(only_gpt)} found only in the user's messages"
             f" · {len(only_claude)} found only in the engineer's register",
             ""]
    for area in sorted({r.get("area", "other") for r in reqs}):
        lines += [f"## {area}", ""]
        for r in [x for x in reqs if x.get("area", "other") == area]:
            tag = {"gpt": "  `[ONE-SIDED: user asked, engineer's list missed it]`",
                   "claude": "  `[ONE-SIDED: engineer's list only]`"}.get(r.get("sources"), "")
            if r.get("clarified"):
                tag += "  `[CLARIFIED by the user — see docs/SPEC.decisions.md]`"
            lines.append(f'- **{r["id"]}** — {r["statement"]}{tag}')
        lines.append("")
    (REPO / "docs" / "SPEC.md").write_text("\n".join(lines))

    clarified = [r["id"] for r in reqs if r.get("clarified")]
    print(f"{len(reqs)} merged → docs/SPEC.md")
    if clarified:
        print(f"  clarified by the user: {', '.join(clarified)}")
    for r in only_gpt:
        print(f'  ONE-SIDED (user asked, not on the engineer\'s list): {r["id"]} — {r["statement"][:80]}')


if __name__ == "__main__":
    main()
