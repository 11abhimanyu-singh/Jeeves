#!/usr/bin/env python3
"""
Jeeves daily diagnosis: one command, the full pipeline, no date limits.

Order matters — deterministic first (free, exhaustive), judgment second:
  1. pull      default.store (+wal/shm) from the cabled iPhone
  2. audit     store-audit.py — every invariant, every row, all history
  3. dump      store-dump.py — the whole state as JSON
  4. coherence coherence-eval.py — third party hunts unknown unknowns and
               proposes new invariants for the audit   (needs OPENAI_API_KEY)
  5. plans     plan-eval.py over ALL stored plans        (needs OPENAI_API_KEY)

Steps 4-5 are skipped with a loud note when no key is in the environment —
skipped is reported, never silent.

Usage:
    python3 tools/diagnose.py <workdir> [--pull] [--device UDID]
    OPENAI_API_KEY=... python3 tools/diagnose.py <workdir> --pull
"""
import os
import subprocess
import sys
from pathlib import Path

DEFAULT_DEVICE = "06032D2A-1BA3-5D5B-9FB2-1CA7105DC03E"
BUNDLE = "abhimanyusingh.me.Jeeves"
TOOLS = Path(__file__).parent


def run(label, cmd, env=None):
    print(f"\n===== {label} =====")
    r = subprocess.run(cmd, env=env)
    print(f"----- {label}: exit {r.returncode}")
    return r.returncode


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    workdir = Path(sys.argv[1])
    workdir.mkdir(parents=True, exist_ok=True)
    device = DEFAULT_DEVICE
    if "--device" in sys.argv:
        device = sys.argv[sys.argv.index("--device") + 1]
    store = workdir / "default.store"

    if "--pull" in sys.argv:
        for f in ("default.store", "default.store-wal", "default.store-shm"):
            rc = subprocess.run([
                "xcrun", "devicectl", "device", "copy", "from",
                "--device", device, "--domain-type", "appDataContainer",
                "--domain-identifier", BUNDLE,
                "--source", f"Library/Application Support/{f}",
                "--destination", str(workdir / f)]).returncode
            if rc != 0 and f == "default.store":
                sys.exit("Pull failed — is the phone cabled and unlocked?")
    if not store.exists():
        sys.exit(f"No store at {store}; run with --pull or copy one in.")

    results = {}
    results["audit"] = run("AUDIT (deterministic, all history)",
                           [sys.executable, str(TOOLS / "store-audit.py"), str(store)])
    dump = workdir / "dump.json"
    results["dump"] = run("DUMP (whole state)",
                          [sys.executable, str(TOOLS / "store-dump.py"), str(store), str(dump)])
    results["trajectory"] = run("TRAJECTORY (story vs state, all sessions)",
                                [sys.executable, str(TOOLS / "trajectory-audit.py"), str(store)])

    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if key:
        results["coherence"] = run("COHERENCE (third party, whole state)",
                                   [sys.executable, str(TOOLS / "coherence-eval.py"), str(dump)])
        # plan-eval expects a data dir with plans.json + state-latest.json; it
        # judges every plan it is given — the caller prepares those from the
        # dump when running the full quality pass.
        if (workdir / "plans.json").exists():
            results["plans"] = run("PLAN QUALITY (all stored plans)",
                                   [sys.executable, str(TOOLS / "plan-eval.py"), str(workdir)])
        else:
            print("\n===== PLAN QUALITY: SKIPPED (no plans.json in workdir) =====")
    else:
        print("\n===== COHERENCE + PLAN QUALITY: SKIPPED — no OPENAI_API_KEY set =====")
        print("      Deterministic layers ran; judgment layers did NOT. Not a clean bill.")

    print("\n===== SUMMARY =====")
    for k, v in results.items():
        print(f"  {k:10} {'OK' if v == 0 else f'FINDINGS (exit {v})'}")
    sys.exit(max(results.values()) if results else 1)


if __name__ == "__main__":
    main()
