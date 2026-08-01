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
  6. tier1     the permanent scenarios in scenarios-chat/dialogues.json, run
               against the real model and judged      (needs BOTH keys)

Steps 4-6 are skipped with a loud note when a key is missing — skipped is
reported, never silent.

WHY TIER 1 IS HERE: steps 2-5 all read the store the user's own use produced.
None of them exercises the permanent scenarios, so for weeks the "permanent
test plan" only ran when somebody remembered to invoke it by hand. A test
plan nobody runs is a document, not a test.

Usage:
    python3 tools/diagnose.py <workdir> [--pull] [--device UDID] [--tier1 N]
    OPENAI_API_KEY=... python3 tools/diagnose.py <workdir> --pull --tier1 3

--tier1 N runs the whole scenario sweep N times (0 skips it). Sampling is the
point: single runs of a probabilistic system are noise.
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


def keychain(service: str) -> str:
    """The login Keychain, so a scheduled run needs no stash file."""
    try:
        return subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                              capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def run_tier1(workdir: Path, repeats: int, openai_key: str) -> int:
    """Play every permanent scenario `repeats` times against the real model,
    then judge each artifact. Returns non-zero if any run had a deterministic
    failure or any judge raised a zero-tolerance finding."""
    anthropic = os.environ.get("ANTHROPIC_API_KEY", "").strip() or keychain("jeeves-anthropic")
    if not anthropic:
        print("\n===== TIER 1 SCENARIOS: SKIPPED — no Anthropic key =====")
        print("      The scenarios drive the REAL chat model; without a key they cannot run.")
        print("      security add-generic-password -s jeeves-anthropic -a jeeves -w")
        return 0

    out = workdir / "tier1"
    env = dict(os.environ, ANTHROPIC_API_KEY=anthropic)
    rc = run(f"TIER 1 SCENARIOS (x{repeats}, real model)",
             [str(TOOLS / "run-trajectories.sh"), "-n", str(repeats), "-o", str(out)], env=env)

    artifacts = sorted(p for p in out.glob("tier1-*.json") if ".judged" not in p.name)
    if not artifacts:
        print("      No artifact produced — the sweep did not complete.")
        return rc or 1

    # Judge only what this sweep produced, newest `repeats` artifacts.
    judge_env = dict(env)
    if openai_key:
        judge_env["OPENAI_API_KEY"] = openai_key
    else:
        oa = keychain("jeeves-openai")
        if oa: judge_env["OPENAI_API_KEY"] = oa
    worst = rc
    for artifact in artifacts[-repeats:]:
        code = run(f"JUDGE {artifact.name}",
                   [sys.executable, str(TOOLS / "trajectory-judge.py"), str(artifact)],
                   env=judge_env)
        worst = max(worst, code)
    return worst


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
    repeats = 0
    if "--tier1" in sys.argv:
        try:
            repeats = int(sys.argv[sys.argv.index("--tier1") + 1])
        except (IndexError, ValueError):
            sys.exit("--tier1 needs a number of repetitions, e.g. --tier1 3")

    key = os.environ.get("OPENAI_API_KEY", "").strip()
    results = {}

    # The store-based layers need a store; Tier 1 does NOT — it builds its own
    # in memory. Gating the scenarios behind a successful pull would mean the
    # permanent test plan silently stops running on every day the phone isn't
    # cabled, which is most of them.
    if store.exists():
        results["audit"] = run("AUDIT (deterministic, all history)",
                               [sys.executable, str(TOOLS / "store-audit.py"), str(store)])
        dump = workdir / "dump.json"
        results["dump"] = run("DUMP (whole state)",
                              [sys.executable, str(TOOLS / "store-dump.py"), str(store), str(dump)])
        results["trajectory"] = run("TRAJECTORY (story vs state, all sessions)",
                                    [sys.executable, str(TOOLS / "trajectory-audit.py"), str(store)])
        if key:
            results["coherence"] = run("COHERENCE (third party, whole state)",
                                       [sys.executable, str(TOOLS / "coherence-eval.py"), str(dump)])
            # plan-eval expects a data dir with plans.json + state-latest.json;
            # it judges every plan it is given — the caller prepares those from
            # the dump when running the full quality pass.
            if (workdir / "plans.json").exists():
                results["plans"] = run("PLAN QUALITY (all stored plans)",
                                       [sys.executable, str(TOOLS / "plan-eval.py"), str(workdir)])
            else:
                print("\n===== PLAN QUALITY: SKIPPED (no plans.json in workdir) =====")
        else:
            print("\n===== COHERENCE + PLAN QUALITY: SKIPPED — no OPENAI_API_KEY set =====")
            print("      Deterministic layers ran; judgment layers did NOT. Not a clean bill.")
    elif repeats > 0:
        print(f"\n===== STORE LAYERS: SKIPPED — no store at {store} =====")
        print("      Running the scenarios anyway; they don't need one.")
    else:
        sys.exit(f"No store at {store}; run with --pull, copy one in, or pass --tier1 N.")

    # ---- 6. The permanent scenarios ----
    if repeats > 0:
        results["tier1"] = run_tier1(workdir, repeats, key)
    else:
        print("\n===== TIER 1 SCENARIOS: not requested (pass --tier1 N) =====")

    print("\n===== SUMMARY =====")
    for k, v in results.items():
        print(f"  {k:10} {'OK' if v == 0 else f'FINDINGS (exit {v})'}")
    sys.exit(max(results.values()) if results else 1)


if __name__ == "__main__":
    main()
