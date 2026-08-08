# Adjudications

When the two registers disagree about what a requirement MEANS — not whether it
exists — the user settles it, and the answer is recorded here.

This file exists so that the correction is attributed to the user rather than
made quietly by whoever is writing the code. `tools/spec-extract.py` re-reads the
transcripts on every run and will keep producing its original wording; entries
here override it, and `docs/SPEC.md` marks every overridden requirement as
CLARIFIED so the change is visible rather than absorbed.

Format: one `## <ID>` heading, the corrected statement, and what was wrong.

---

## FITNESS-01
2026-08-08

**Statement:** Two recorded sessions of the same type on one day are normal — the
user takes a water break, a phone call, the toilet, and the watch ends one
session and starts another. Nothing may treat that as a duplicate, a clone or an
anomaly. Only an identical start minute, type and duration indicates a duplicate
import.

**What the extraction got wrong:** it generalised the statement into "workout
plans may be split into separate segments with breaks between segments", which
reads as a request to PLAN the gym as several blocks. That is a different
feature, and it contradicts the deliberate design in `DayPlanner` — the gym is
one block, and what happens inside it is logged in Fitness.

The original statement was about workouts already RECORDED (3 and 4 August each
hold two lifts and two runs), not about how the day is planned.
