#!/usr/bin/env python3
"""
Jeeves store dump: the WHOLE state as normalized JSON, for third-party review.

The eval lenses each see one artifact; the coherence eval needs everything —
a judge can only find contradictions in data it was actually handed. This
emits every row of every table with dates as ISO strings and UUIDs as hex.
Binary payloads (thumbnails, chat images) are elided to their byte size;
nothing else is truncated or filtered — no date limits, no sampling.

Usage:
    python3 tools/store-dump.py <default.store> [out.json]
"""
import datetime
import json
import sqlite3
import sys
from pathlib import Path

EPOCH = 978307200
DISTANT_PAST_CUTOFF = -60000000000
BINARY_ELIDE = ("ZTHUMBNAILDATA", "ZIMAGEDATA")


def is_dateish(col):
    # Suffix match, not substring — "AT" as a substring also hits ZDURATIONMS.
    return (col.endswith(("DATE", "AT", "TIMESTAMP")) or col.startswith("ZDATE")
            or col == "ZARRIVEBY")


def convert(col, v):
    if v is None:
        return None
    if isinstance(v, bytes):
        if col in BINARY_ELIDE:
            return f"<{len(v)} bytes>"
        return v.hex()
    if isinstance(v, (int, float)) and not isinstance(v, bool) and is_dateish(col):
        if v < DISTANT_PAST_CUTOFF:
            return "distantPast"
        try:
            return datetime.datetime.fromtimestamp(v + EPOCH).isoformat(timespec="minutes")
        except (ValueError, OSError, OverflowError):
            return f"<unparseable {v}>"
    return v


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = Path(sys.argv[1])
    out_path = Path(sys.argv[2]) if len(sys.argv) > 2 else path.with_suffix(".dump.json")
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row

    dump = {"generatedFrom": str(path), "tables": {}}
    tables = [r[0] for r in db.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%'"
        " AND name NOT LIKE 'Z\\_%' ESCAPE '\\'")]
    for t in sorted(tables):
        rows = []
        for r in db.execute(f"SELECT * FROM {t}"):
            rows.append({k: convert(k, r[k]) for k in r.keys()
                         if k not in ("Z_PK", "Z_ENT", "Z_OPT")})
        dump["tables"][t] = rows

    out_path.write_text(json.dumps(dump, indent=1, default=str))
    total = sum(len(v) for v in dump["tables"].values())
    print(f"{total} rows across {len(dump['tables'])} tables → {out_path}")


if __name__ == "__main__":
    main()
