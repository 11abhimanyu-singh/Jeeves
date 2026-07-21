# Jeeves — Product Requirements Document

**For:** Claude Code (implementation)
**Context:** This PRD is the source of truth. It was produced from an extended product-design conversation. Everything here is decided unless explicitly marked OPEN. Build from this; don't re-derive decisions already made.

---

## 1. What Jeeves is

A personal iOS productivity app (SwiftUI + SwiftData, iOS 17+) for a single user (the owner, "Abhi"). Purpose: hold the user accountable to daily goals and intelligently plan each day around fixed commitments.

Two pillars:
1. **Fitness accountability** — already built and working. Do not rebuild unless asked. (Details in §3 for context only.)
2. **Day Planner, driven by a conversational agent named "Jeeves"** — the main new work. This is a re-architecture, not a tweak to the existing deterministic planner. Build the new version fresh alongside the old one, then swap.

The guiding principle: **use Claude's intelligence for judgment, not just arithmetic.** Every hard scheduling case in design was solved by human-style reasoning (chaining trips, using on-site facilities, relocating flexible activities), not by packing blocks into gaps. The app should reason the same way, via a live Claude API call, with a deterministic engine as offline fallback.

---

## 2. Current state of the codebase

Working Xcode project named **Jeeves**. Existing files:
- `JeevesApp.swift` — app entry, SwiftData `ModelContainer` with schema registering all models.
- `ContentView.swift` — 4-tab shell (Check-in / Progress / History / Planner) + the shared design-token color palette and `Font.heading` helper. Fitness tabs live here.
- `Item.swift` — contains the `CheckIn` SwiftData model (filename is legacy; type name is what matters).
- `JobPrep.swift` — `JobApplication`, `PrepSession`, `PrepCategory`.
- `HabitLog.swift` — `HabitLog`, `HabitType` (reading, photography).
- `DailyPlanState.swift` — persists today's gym toggle + time.
- `DailyEvent.swift` — one-off events as scheduling anchors.
- `DayPlanner.swift` — the **deterministic** planning engine (gym-pivot + multi-anchor). Keep as the fallback engine; see §6.
- `DayPlannerView.swift` — current planner UI (gym time input, event form, schedule list, tap-to-log completion).

**First action in Claude Code:** build the project and confirm it compiles cleanly before changing anything. There was a history of a duplicate `CheckIn` definition; verify it's resolved.

---

## 3. Design system (do not deviate)

**FINAL DIRECTION: dark-warm palette + NYT-style editorial serif typography.** This was chosen after comparing a cozy-rounded light theme, an austere light-editorial theme, a warm-editorial theme, an almanac theme, and dark-warm across four font pairings. The visual spec is the file `jeeves-darkwarm-nyt-stacked.png` (rendered mockup) with `jeeves-darkwarm-nyt.html` as the reference implementation — treat these as the source of truth for look & feel and match them.

**Palette** (dark warm) — define once via a `Color(hex:)` extension:
- Background `#211A14`, surface `#2E2620`, surface2 `#38302A`
- Text `#F0E4D0`, textSoft `#C3B49B`, textMuted `#8A7B64`
- Accent (terracotta, brightened for dark bg) `#E08A4E`; deeper terracotta `#C67139` for pressed/filled states
- Sage `#9DAE78`, sageDeep `#7E8F5B`
- Hairline rule color `rgba(240,228,208,0.12)`

**Typography** — editorial serif, NYT-inspired:
- **Display / headings / screen titles / activity names / big stats / italic asides:** a classic high-contrast serif. Ship **PT Serif** (bundled) with **Georgia** as the system fallback. (The actual NYT fonts — Cheltenham/Imperial — are proprietary and must NOT be used or bundled.)
- **Times, numeric data, labels/eyebrows, tab bar, body/UI text:** a clean sans — **Inter** (or system default as fallback). Keep numerals in the sans for legibility and tabular alignment.
- Bundle PT Serif + Inter as font files in the Xcode project (this direction *does* require real fonts, unlike the earlier placeholder note). Register them in Info.plist.

**Layout language** — editorial, not card-heavy:
- Every screen opens with a **masthead**: small uppercase terracotta eyebrow (kicker) → large serif title → optional dateline row (date left, status right).
- **Timeline is the signature:** the day plan renders as a chronological agenda with time as the left spine (sans, tabular), hairline/subtle-fill separation between entries, anchor entries (gym, events, peak-focus) tinted with a surface fill and terracotta time labels. Activity names in serif.
- Restrained accent: terracotta used sparingly (anchor times, one big number, the streak) rather than filling every control.
- Radius scale 8 / 16 / 28px; soft fills over hard borders; hairline rules for division.

**Light theme (deferred):** the warm-editorial *light* palette (bg `#F5EAD8`, surface `#EBDDC5`, text `#201E1D`, accent `#C67139`, sage `#7A8A5E`) shares this exact layout, so a light/dark toggle is a low-effort future addition — build the dark theme first, keep colors in tokens so a theme swap stays trivial.

All new UI (chat, settings, plan display) must use these same tokens and the serif/sans split above.

---

## 4. Fitness module (context only — already built, leave alone)

Daily check-in: "Did you work out?" → multi-select Weight training / Stretching / Mobility / Cardio → if Cardio, choose Running or Inclined Walk → both ask Duration (min) and Incline (%, decimal-allowed). Monthly goal 20 workout days shown as a ring. History list. Smart banner: shows "yesterday's check-in waiting" until done, then flips to "log today's."

---

## 5. Day Planner — the vision

Replace the forms-and-buttons planner with a **conversational agent, "Jeeves."** The user talks to Jeeves in natural language (like a chat) to plan the day. Structured data still lives underneath; conversation is the primary interface.

### 5.1 Fixed daily activities and durations (the user's baseline routine)

Movable blocks (fit into the day around anchors), each with a **priority tier**:

| Activity | Duration | Tier |
|---|---|---|
| Interview prep — Reading (morning peak-focus) | 90 min | **Must-do** |
| Lunch | 45 min | **Must-do** |
| Job applications | 90 min | Important |
| Interview prep — practice (Product Sense / Execution / Strategy / Behavioral) | 120 min total | Important |
| Reading habit | 90 min | Important |
| Chores | 40 min | Flexible |
| Chore buffer | 30 min | Flexible |
| Photography | 30 min | Flexible |

Priority tiers: **Must-do** (never dropped; shrink only as absolute last resort) > **Important** > **Flexible** (dropped first). Anchors (gym, events) sit above all tiers — non-negotiable fixed commitments.

Interview-prep practice (120 min) is split across the 4 categories, weighted toward whichever has the fewest `PrepSession` entries in the last 7 days (most-neglected gets most time). The current deterministic split is 45/35/25/15 by neglect rank.

### 5.2 The day window and boundaries

- **Productive window:** 8:00 AM – 8:30 PM on a normal day.
- **Normal day:** hard boundary = 8:30 PM.
- **Event day:** hard boundary = **the departure time for the event.** All planned work must fit *before* the user leaves for the event. After returning home from an event, nothing is scheduled — that's wind-down. (The event and late return exist outside the plan.)

### 5.3 Overflow logic (when everything doesn't fit before the boundary)

Deterministic order, applied against whichever boundary is in force:
1. **Drop lowest-priority first:** all Flexible, then Important. Never drop Must-do.
2. **Then shrink** whatever survives proportionally so the day fits exactly.
3. **Within a tier, which item to drop/shrink first is Claude's judgment** (not a fixed rule) — e.g. "keep job applications, defer reading habit, shrink prep" vs "shrink all three a little," possibly informed by context like an upcoming interview date. Deterministic fallback when offline: largest-item-first within the tier.
4. Always **show the user what was dropped/shrunk** ("Dropped today to fit: Chores, Chore buffer, Photography"). Never silently vanish items.

### 5.4 Anchors, locations, commute, chaining

**Saved locations** (set once): **Home**, **Work**, **Gym** — each with an address and a declared set of on-site facilities/activities. Example facility data:
- Home: reading, job apps, prep, lunch, chores, photography (sleep implicit)
- Gym: weightlifting, cardio, mobility, **shower**
- Work: (user-defined)

**Gym routing:** always Home → Gym → Home (fixed). Gym outbound is always from Home for now.

**Event routing:** outbound start point is **asked each day** (Home / Work / Gym — from saved locations), because it varies. Return is **always Event → Home** (fixed). Events are not saved locations; each event carries its own destination address.

**Commute time must be real,** computed from actual start→destination with live traffic via the **Google Maps API** (Directions/Distance Matrix). Do not hardcode 30 min. Deterministic fallback when offline/unkeyed: a user-set default (e.g. 30 min).

**Chaining (a core intelligence requirement):** Jeeves must reason like a human planner, not a block-packer. Concretely, from the stress-test cases:
- If two anchors are adjacent in time and location (e.g. gym ends near the movie venue), **route gym → event directly**, skipping the gym→home→event detour.
- **Use on-site facilities:** if leaving straight from gym to an event, take the **shower at the gym** rather than deferring it.
- **Relocate flexible activities:** e.g. "eat near the venue around showtime" rather than forcing lunch into a fixed at-home slot. Jeeves may infer reasonable options (food near a public venue) without the user entering them.

**Anchor conflict handling:** if two fixed anchors physically overlap (can't be at the gym until 1:15 and also leave for a movie at 12:30), **detect and flag the clash to the user and let them choose** (shift gym, skip gym, etc.). Do NOT auto-drop an anchor silently.

### 5.5 Event ingestion (in priority order of value)

1. **Google Calendar (primary source of truth).** User connects their Google account via **OAuth**. App reads events + their location fields via the Google Calendar API. If an event's location is missing, Jeeves asks the user (or accepts a screenshot).
2. **Screenshot ingestion.** User uploads a ticket screenshot (e.g. BookMyShow-style: venue, date, time, seat). Send the image to Claude's **vision** API; Claude extracts venue/date/time and pre-fills an event for the user to confirm. Must handle arbitrary ticket layouts (that's why it's Claude vision, not hardcoded parsing).
3. **Manual entry.** Always-available fallback: title, start, end, destination address, outbound start point.

### 5.6 Jeeves conversational agent

A chat interface inside the app (its own tab or entry point), styled with the design tokens, that the user talks to like a normal chat. Jeeves:
- Accepts natural-language planning input ("movie at 2, gym at 11, leaving from home").
- Asks for missing info (locations it doesn't know, ambiguous times).
- Produces and explains the day's plan, including chaining decisions and what was dropped/shrunk and why.
- Backed by the Claude API (see §6). Conversation history for the current planning session is passed with each call (stateless API; app maintains context).

---

## 6. Architecture: Claude-generated plan + deterministic fallback

- **Primary:** Jeeves calls the **Claude API** to generate the plan holistically, given: the user's baseline activities + tiers (§5.1), saved locations + facilities (§5.4), today's anchors (gym + events), real commute times (Google Maps), and the boundary/overflow rules (§5.2–5.3). Claude returns a structured schedule (list of blocks: title, start, end, note/reasoning, and for droppable items which were dropped/shrunk). Design the prompt + a strict JSON response contract so the app can parse and render it.
- **Fallback:** the existing deterministic `DayPlanner.swift` engine runs when the API is unreachable (no network, no key, error). It already implements gym-pivot + multi-anchor packing; extend it to honor priority tiers and the drop-then-shrink rule with the deterministic within-tier ordering (largest-first). The app must always produce *a* plan, even offline.
- Parse Claude's response **by content/type, never by array position.** Handle malformed/partial responses gracefully and fall back.

---

## 7. Secrets & security

- **Anthropic API key:** required for Jeeves chat, plan generation, and screenshot vision. User obtains it from platform.claude.com (console.anthropic.com). Provide a one-time in-app settings screen to paste it; store it in the **iOS Keychain**, never in source, never in UserDefaults, never committed to git.
- **Google OAuth tokens:** stored securely (Keychain) per platform best practice. Follow Google's iOS OAuth flow.
- **Google Maps API key:** stored securely; restrict it in the Google Cloud console.
- Never ship any key in client source. If a `.xcconfig` or similar is used for non-secret config, ensure secrets are excluded from version control.

---

## 8. Data models (extend as needed)

Existing: `CheckIn`, `JobApplication`, `PrepSession`/`PrepCategory`, `HabitLog`/`HabitType`, `DailyPlanState`, `DailyEvent`. All registered in `JeevesApp.swift`'s `Schema([...])`.

New models likely needed (design as appropriate):
- `SavedLocation` (name enum Home/Work/Gym, address, facilities list).
- Richer `DailyEvent` (destination address, outbound start location, source: calendar/screenshot/manual).
- Chat message / planning-session storage for Jeeves.
- Settings/secrets are **not** SwiftData — Keychain.

---

## 9. Build sequence (do not build all at once)

Each step should leave the app runnable.

1. **Confirm current build is clean.**
2. **Secrets foundation:** Keychain wrapper + settings screen to enter the Anthropic API key. (Prerequisite for everything intelligent.)
3. **Jeeves chat interface:** basic conversational screen wired to the Claude API (text-only first). Prove the loop: user message → API → response rendered, with session history.
4. **Claude-powered plan generation:** give Jeeves the baseline activities, tiers, and boundary/overflow rules; have it produce a structured plan from natural-language + today's anchors. Render it. Keep deterministic engine as fallback.
5. **Saved locations + facilities** model and setup UI; feed into planning.
6. **Google Maps commute routing** with real traffic; replace hardcoded commute. Fallback default when unavailable.
7. **Chaining + facilities intelligence** in the plan prompt (gym→event direct, gym shower, relocate flexible items, conflict flagging).
8. **Event ingestion — manual** (richest fields) → **screenshot/vision** → **Google Calendar OAuth**, in that order.
9. Polish: dropped/shrunk transparency UI, offline fallbacks everywhere, error states.

---

## 10. Known deferrals / non-goals (don't silently build these)

- No multi-user / accounts / sharing. Single user.
- No iCloud sync yet (SwiftData supports it; deferred until core works).
- No un-log/undo for completion taps yet (nice-to-have).
- Custom fonts ARE now required (PT Serif + Inter — see §3); bundle them. (This supersedes the earlier Caprasimo/Figtree placeholder plan.)
- Light theme is deferred (dark-warm ships first); keep colors in tokens so a toggle is easy later.
- "Food near venue" specifics can be Claude-inferred; don't build a places database.
- Gym outbound is always Home for now (don't add per-day gym start-point picking unless asked).

---

## 11. User profile (for tone & collaboration)

New to Swift/iOS; learning as they go. Explain *why* when it aids learning, but don't over-explain trivia. Prefers deliberate, confirm-as-you-go progress over large unstructured dumps. Strong product instincts — defer to the user on product decisions; this PRD already encodes their choices. When a genuinely new design question arises (not covered here), surface it and ask rather than guessing.
