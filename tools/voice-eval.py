#!/usr/bin/env python3
"""
Jeeves voice-note eval: Whisper as the reference transcriber.

Reads the voice notes Jeeves mirrors to iCloud Drive (state-latest.json for
the on-device transcripts + VoiceNotes/*.m4a for the audio), re-transcribes
each recording with OpenAI Whisper, and reports the on-device recognizer's
word-error rate for THIS user's voice (Indian English). High WER on specific
words = candidates for the recognizer's contextual-vocabulary list; high WER
overall = consider promoting Whisper to primary transcription.

Usage:
    OPENAI_API_KEY=sk-... python3 tools/voice-eval.py
Writes voice-eval.json next to the notes and prints a summary table.
No key is stored anywhere; it is read from the environment only.
"""
import json
import os
import sys
import urllib.request
import uuid
from pathlib import Path

CONTAINER = Path.home() / "Library/Mobile Documents/iCloud~abhimanyusingh~me~Jeeves/Documents"
STATE = CONTAINER / "state-latest.json"
AUDIO_DIR = CONTAINER / "VoiceNotes"
OUT = CONTAINER / "voice-eval.json"
WHISPER_URL = "https://api.openai.com/v1/audio/transcriptions"


def whisper(path: Path, key: str) -> str:
    boundary = uuid.uuid4().hex
    body = b""
    def field(name, value):
        return (f"--{boundary}\r\nContent-Disposition: form-data; "
                f"name=\"{name}\"\r\n\r\n{value}\r\n").encode()
    body += field("model", "whisper-1")
    body += field("language", "en")
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
             f"filename=\"{path.name}\"\r\nContent-Type: audio/m4a\r\n\r\n").encode()
    body += path.read_bytes() + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    req = urllib.request.Request(WHISPER_URL, data=body, headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    })
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r).get("text", "").strip()


def norm(text: str) -> list[str]:
    """Lowercase, strip punctuation — compare words, not formatting."""
    cleaned = "".join(c.lower() if c.isalnum() or c.isspace() else " " for c in text)
    return cleaned.split()


def wer(reference: list[str], hypothesis: list[str]) -> float:
    """Classic Levenshtein word-error rate."""
    if not reference:
        return 0.0 if not hypothesis else 1.0
    d = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, 1):
        prev = d[0]
        d[0] = i
        for j, hyp_word in enumerate(hypothesis, 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (ref_word != hyp_word))
            prev = cur
    return d[-1] / len(reference)


def main() -> None:
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        sys.exit("Set OPENAI_API_KEY in the environment (never store it in the repo).")
    if not STATE.exists():
        sys.exit(f"No state-latest.json at {STATE} — open Jeeves on the phone so it exports.")
    notes = json.loads(STATE.read_text()).get("voiceNotes", [])
    with_audio = [n for n in notes if n.get("audioFile")]
    if not with_audio:
        print("No voice notes with audio yet — record some in chat first.")
        return

    results, missing = [], 0
    for n in with_audio:
        audio = AUDIO_DIR / n["audioFile"]
        if not audio.exists():
            missing += 1
            continue
        try:
            reference = whisper(audio, key)
        except Exception as e:  # keep going; report per-note failures
            results.append({"date": n["date"], "error": str(e)[:200]})
            continue
        ondevice = n.get("transcript", "")
        score = wer(norm(reference), norm(ondevice))
        results.append({
            "date": n["date"], "durationSec": n.get("durationSec"),
            "onDevice": ondevice, "whisper": reference,
            "wer": round(score, 3),
        })

    scored = [r for r in results if "wer" in r]
    summary = {
        "notes": len(with_audio), "scored": len(scored),
        "audioMissingLocally": missing,
        "meanWER": round(sum(r["wer"] for r in scored) / len(scored), 3) if scored else None,
        "worst": sorted(scored, key=lambda r: -r["wer"])[:5],
        "results": results,
    }
    OUT.write_text(json.dumps(summary, indent=2))

    print(f"\n{len(scored)} notes scored"
          + (f" · mean WER {summary['meanWER']:.1%}" if scored else "")
          + (f" · {missing} audio files not yet synced" if missing else ""))
    for r in scored:
        flag = "⚠️ " if r["wer"] > 0.25 else "   "
        print(f"{flag}{r['date']}  WER {r['wer']:.1%}")
        if r["wer"] > 0:
            print(f"     on-device: {r['onDevice'][:90]}")
            print(f"     whisper  : {r['whisper'][:90]}")
    print(f"\nFull report: {OUT}")


if __name__ == "__main__":
    main()
