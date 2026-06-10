# Session 15 — Logo + Presentation Deck + Recorded Demo

**Date:** 2026-06-08 → 2026-06-09
**Branch:** `feat/slides`
**Deliverables:**
- `docs/RangeGuard-Demo-Deck.pptx` — 6-slide Google-Slides-ready deck
- `docs/assets/` — RangeGuard logo (8 SVGs) + partner logos
- `docs/build_assets.py`, `docs/build_deck.py` — reproducible builders
- **Demo video:** https://www.youtube.com/watch?v=82_9mEh_POM (~3m 53s)

> This session ran in two parts: an initial 9-slide deck build, then a **Logo + Slides Rebuild**
> (the opening prompt of which is reproduced verbatim below) that produced the final 6-slide deck and
> the logo. The recorded demo was then published to YouTube. This document is the close-out record.

---

## 1. Opening prompt (verbatim) — "RangeGuard — Logo + Slides Rebuild"

```
RangeGuard — Logo + Slides Rebuild
Branch: feat/slides (already exists — continue on this branch)
Mandatory first steps:

Read docs/demo-narrative.md
Read docs/demo-run-output.md
Read docs/session-15-slides.md (existing deck context)
Confirm understanding before writing any code


PHASE 1 — Generate Logo (stop and wait for approval before Phase 2)
Generate the RangeGuard logo as SVG files. Save to docs/assets/:
Design spec:
Shield shape: Classic shield, slightly rounded bottom point
              Proportions: ~1:1.2 width:height ratio

Inside the shield: 3 vertical bars of different heights
  - Left bar:   60% of shield height, width = 12% of shield width
  - Center bar: 85% of shield height, width = 12% of shield width
  - Right bar:  45% of shield height, width = 12% of shield width
  - Bars positioned centered horizontally, bottom-aligned
  - Gap between bars: 8% of shield width
  - Bar color: #00d395 (accent green)

Shield fill: transparent (see-through center shows bars)
Sstroke: gradient left-to-right #FF007A → #9B59B6
Shield stroke width: 3px
Generate four variants:
docs/assets/logo-icon.svg — icon only, 64×64 viewBox:
Just the shield + bars, no text
docs/assets/logo-standalone.svg — icon + name, horizontal layout:
[Shield 48px] [RangeGuard — Calibri Bold, 32px, #ffffff]
Total width ~300px
docs/assets/logo-full.svg — icon + name + tagline, stacked:
[Shield 64px centered]
[RangeGuard — Calibri Bold, 36px, #ffffff, centered]
[Protect your liquidity. Guard your range. — Calibri Regular, 16px, #94a3b8, centered]
Total height ~140px
docs/assets/favicon.svg — 32×32, icon only, simplified:
Same as logo-icon but optimized for 32px display
Stroke width: 2px at this size
After generating all four variants:

Present them for review
STOP — do not proceed to Phase 2 until user explicitly approves the logo
If changes are requested, regenerate and present again
Only proceed to Phase 2 after explicit approval


PHASE 2 — Rebuild Slide Deck (only after logo approval)
d-Demo-Deck.pptx with the following changes from the previous version:
Structural changes:

Remove old Slides 1-2 (IL explanation — judges know IL)
Remove old Slide 7 (demo transition)
Remove old Slide 8 (coverage report transition)
Add new Title slide as Slide 1
Result: 6 slides total

Logo placement:

Title slide: logo-full.svg centered, prominent
All other slides: logo-icon.svg top-left corner, 24px height, subtle
Closing slide: logo-standalone.svg top center

Partner logos:

Download or reference Uniswap logo SVG from official source
Download or reference Reactive Network logo from official source
Save to docs/assets/uniswap-logo.svg and docs/assets/reactive-logo.svg
Title slide: both logos very small at bottom, with "Built on" and "Powered by" labels, slate gray
Closing slide: both logos small but visible, same labels


The 6 slides — complete spec:
Slide 1 — Title
[Full logo centered — logo-full.svg]

[Presenter line — bottom center, slate gray]
Gary Kocsis
Uniswap Hook Incubator

[Partner ly bottom, small]
Built on [Uniswap Logo]  ·  Powered by [Reactive Network Logo]
Speaker notes:

"Hello everyone, my name is Gary Kocsis, and I'm excited to present RangeGuard — Protect your liquidity. Guard your range. As many of you know, impermanent loss is the single biggest reason liquidity providers leave AMMs. Even with fee rewards, most LPs lose money when prices move — and there's no native, on-chain way to protect them. Until now."


Slide 2 — The Solution
[Label] THE SOLUTION
[Icon top-left — 24px]

[Headline]
RangeGuard turns impermanent loss
into an earned, capped, on-chain claim.

[Five bullets]
- Coverage accrues only while in range —
  exposure-weighted, not time-weighted
- Day-count convention (Actual/365 Fixed) —
  predictable, auditable, comparable across pools
- Buffer funded by dynamic fee skimming —
  sustainable, no external subsidies
- Automatic payout on withdrawal —
  capped by earned coverage, buffer health, and protocol params
- Reactive Network integration —
  etected cross-chain, no keepers

[Tagline — accent color, bottom]
"Protect your liquidity. Guard your range."
Speaker notes:

"RangeGuard brings native, transparent IL coverage directly into a Uniswap v4 pool. When an LP provides liquidity, they start earning coverage — but only while their position is in range and exposed to IL risk. Coverage accrues using a day-count convention — just like traditional finance — so LPs can see exactly how much protection they're earning and compare it across pools. The coverage buffer is funded by a small configurable portion of trading fees via Uniswap v4's dynamic fee system — sustainable, no external subsidies. When an LP withdraws, the hook automatically calculates their impermanent loss and pays out a capped reimbursement — bounded by what they've earned, the buffer's health, and protocol parameters. And the system runs autonomously. RangeGuard integrates with the Reactive Network — a cross-chain automation layer running on Lasna — so range transitionsd recorded automatically. No keeper bots. No off-chain infrastructure."


Slide 3 — Economic Flywheel
[Label] THE SOLUTION
[Icon top-left — 24px]

[Headline]
Self-Funding by Design

[Two-row flow diagram — NOT circular, two rows with wrap]

Row 1 (left to right, with right arrows):
[LPs provide liquidity] → [Traders use the pool] → [Swaps generate fees]
                                                              ↓ (down arrow)
Row 2 (right to left, with left arrows):
[LPs are protected] ← [Buffer pays capped IL] ← [Buffer slice skimmed]
     ↑ (up arrow on far left connecting back to Row 1 start)

Box styling: card bg #1e2433, white text, rounded corners
Arrow color: accent green #00d395
Highlight boxes 4 and 5 (Buffer slice skimmed, Buffer pays capped IL)
with accent color border

[Single line — accent color, centered, bottom]
Swap activity funds the buffer that protects LPs.
Speaker notes:

"The economics are self-sustaining. LPs provide liquidity, traders use the pool, swaps generation funds the coverage buffer, and the buffer pays capped IL claims. The buffer grows from the same swap activity that LP liquidity enables. No external capital required."


Slide 4 — Five Pillars
[Label] THE SOLUTION
[Icon top-left — 24px]

[Headline]
How RangeGuard Works: Five Pillars

[Five items — numbered, left aligned, evenly spaced]

1. Accrual Gating
   Coverage accrues only while the position is in range

2. Buffer Funding
   A portion of every swap fee funds the coverage buffer

3. Claim Settlement
   IL computed and paid automatically on withdrawal
   Payout = min(covered IL, earned coverage, buffer cap)

4. LP Transparency  ★
   A verifiable, day-by-day coverage report —
   built entirely from on-chain events
   [Highlighted — accent color left border or background]

5. Pool Configuration
   Immutable parameters set once at pool initialization

[Bottom — accent color]
Every pillar is enforced on-chain. No off-chain assumptions.
Speaker notes:

"RangeGuard is built on five pillars.  — coverage only earns while in range. Buffer funding — every swap contributes automatically. Claim settlement — IL is computed and paid in the same withdrawal transaction, capped by three limits: covered IL, earned coverage, and buffer capacity. LP transparency — the key differentiator — a verifiable day-by-day coverage statement from pure on-chain events. And pool configuration — immutable parameters, so LPs always know what they signed up for."

Verbal transition:

"Let me show you the core functions that make this work."


Slide 5 — Code Walkthrough
[Label] UNDER THE HOOD
[Icon top-left — 24px]

[Headline]
How Coverage Becomes a Claim

[Horizontal lifecycle flow — 6 boxes, ALL SAME COLOR]
All boxes: card bg #1e2433, white text, accent color border
Arrow color: accent green

LP Deposits → _accrue() → afterSwap() → _computeIL() → _computePayout() → ClaimSettled

Note: "ClaimSettled" — ensure correct spelling, no spell-check underline

[Two amber callout boxes — side by side]

Left:
⚡ Swaps never iterate positions
   Accrual is lazy, position-specific
   O(1) gas on every swap

Right:
⚡ Actual/365 Fixed day-count
   Coverage = Notional × APR × (days ÷ 365)
   Same convention as fixed-income finance

[Bottom — accent color]
One lifecycle. Fully on-chain. No off-chain assumptions.
Speaker notes:

"Before the demo, here's the core code path. _accrue advances coverage lazily — only while in range, using Actual/365 Fixed day-count math. _computePayout applies three caps in order. The day-count convention turns coverage from a black-box reward into an auditable financial accrual. Let me show you."

IDE narration:

"_accrue: range gate first — if the tick is outside the LP's bounds, delta is zero. If in range — year fraction from day-count basis, multiplied by entry notional and APR. Fifteen days in range earns exactly 15/365 of the annual coverage amount. _computePayout: three caps in order — IL cap, earned coverage cap, buffer cap. Minimum of all three. Limiting faceived what they received."


Slide 6 — Closing
[Logo — logo-standalone.svg, top center]

[Tagline — accent color, centered]
"Protect your liquidity. Guard your range."

[Four bullets — white]
✓ Native IL coverage — built into the pool, not bolted on
✓ Self-funding buffer — swap fees cover the claims
✓ Capped payouts — actuarially sound, buffer protected
✓ Fully auditable — every accrual verifiable on-chain

[Beneficiary table — card bg]
Who Benefits          Why It Matters
─────────────────     ──────────────────────────────────
Passive LPs           Downside protection without complex hedging
Protocols / DAOs      Deeper liquidity without reliance on emissions
Uniswap Ecosystem     Durable liquidity, tighter spreads, better execution

[Closing line — large, accent color, centered]
Earned over time. Funded by swaps. Settled on-chain.

[Divider]

[Two columns — links]
🔗 rangowered by [Reactive Network Logo]

[Very bottom — slate gray]
292 tests passing  ·  Fuzz tested  ·  Invariant tested
Speaker notes:

"RangeGuard makes providing liquidity safer, more transparent, and more attractive — helping Uniswap pools retain and grow their LP base. The primary beneficiaries are passive LPs who get downside protection without complex hedging. But the impact extends to protocols that need sticky liquidity without emissions, and to the broader ecosystem through deeper pools and better execution. Earned over time. Funded by swaps. Settled on-chain. Live dashboard at range-guard.vercel.app. Full source and 292 passing tests on GitHub. Thank you."


After generating the deck:

Present docs/RangeGuard-Demo-Deck.pptx for download
Update docs/session-15-slides.md with changes made
Update project-status.md
Do NOT write additional closing docs — session is ongoing  - keep this prompt and add it to the session-15 closing document when given the instruction to update the closing documents
```

---

## 2. Logo variants generated and their usage

All logos live in `docs/assets/`. The mark: a **classic shield** (gradient stroke `#FF007A → #9B59B6`
left→right, transparent fill) wrapping **three green (`#00d395`) vertical bars** — a "range" bar-chart
guarded by a shield. Bars: left 60% / center 85% / right 45% height, 12%-width, 8% gaps, centered +
bottom-aligned (center bar is rendered at ~80% rather than a literal 85% so it doesn't poke through
the shield's rounded top).

| File | Spec | Used in the deck |
|---|---|---|
| `logo-icon.svg` | 64×64, shield + bars, 3px stroke | Top-left corner of every content slide (2–5), ~24px, beside the section label; also the shield glyph in the Title & Closing lockups |
| `favicon.svg` | 32×32, simplified, 2px stroke | Not embedded in the deck — favicon asset for the frontend/site |
| `logo-standalone.svg` | 300×64, icon + "RangeGuard" (Calibri Bold 32, white) | Closing-slide lockup (composed natively — see §4) |
| `logo-standalone-light.svg` | as above, name `#0f1117` (dark) | Light-background placements (added on request) |
| `logo-full.svg` | 360×140, icon + name (36, white) + tagline (16, `#94a3b8`) | Title-slide lockup (composed natively — see §4) |
| `logo-full-light.svg` | as above, name `#0f1117`, tagline `#4a5568` | Light-background placements (added on request) |

**Partner logos** (fetched from official sources):

| File | Source | Used in the deck |
|---|---|---|
| `uniswap-logo.svg` | cryptologos.cc — the pink unicorn mark (`#F50DB4`) | Title + Closing, under "Built on" |
| `reactive-logo.svg` | `dev.reactive.network/img/rn-docs-logo-white.svg` | Title + Closing, under "Powered by" |
| `reactive-logo-dark.svg` | `dev.reactive.network/img/rn-docs-logo-black.svg` | Dark-text variant kept for light backgrounds |

The Reactive asset is a `reactive | Dev` lockup; for the embedded partner badge the `| Dev` suffix is
cropped off (`keep_left=0.685` in `build_assets.py`) to leave a clean `reactive` icon + wordmark.

---

## 3. Slide-structure decisions (9 → 6 slides)

Removed from the prior 9-slide deck and why:
- **Old Slides 1–2 (IL explanation: statement/mechanism + the math)** — removed; the audience
  (Uniswap Hook Incubator judges) already understands impermanent loss, so the deck opens on the
  solution instead of teaching the problem.
- **Old Slide 7 (Demo Script transition)** and **old Slide 8 (Coverage Report transition)** —
  removed; these were lead-ins to the live demo/dashboard, which the recorded video now covers
  directly, so the static deck doesn't need transition slides.
- **Added a Title slide** (logo, presenter, partner attributions) as the new Slide 1.

Final 6 slides:
1. **Title** — full lockup (shield + "RangeGuard" + tagline) centered; "Gary Kocsis / Uniswap Hook
   Incubator"; "Built on [Uniswap] · Powered by [Reactive]".
2. **The Solution** — headline + 5 two-line bullets + tagline.
3. **Economic Flywheel** — two-row flow **loop** (not circular): row 1 L→R, down arrow on the right,
   row 2 R→L, up arrow on the left back to the start; the two buffer boxes accent-bordered.
4. **Five Pillars** — numbered; Pillar 4 (LP Transparency ★) highlighted with an accent border.
5. **Code Walkthrough** — 6-box lifecycle (`LP Deposits → _accrue() → afterSwap() → _computeIL() →
   _computePayout() → ClaimSettled`), all boxes the same accent-bordered style; two amber callouts.
6. **Closing** — standalone lockup top center; ✓ bullets; beneficiary table; "Earned over time.
   Funded by swaps. Settled on-chain."; dashboard + GitHub links; partner logos; 292-tests footer.

Full speaker notes (including verbal transitions and IDE narration) are carried in every slide's
notes panel, verbatim from the prompt.

Design system (all slides): bg `#0f1117` · white `#ffffff` · accent `#00d395` · slate `#94a3b8` ·
amber `#f59e0b` · danger `#ef4444` · card `#1e2433`; Calibri; 16:9 (13.333"×7.5").

---

## 4. Build pipeline & verification

python-pptx **cannot embed SVG**. The only local renderer (macOS `qlmanage`) composites SVGs on an
opaque **white** background, so `docs/build_assets.py` renders each needed SVG with a matching navy
(`#0f1117`) background rect, **keys that navy to transparent**, crops to a tight content box, and
writes PNGs to `docs/assets/png/`. `docs/build_deck.py` embeds those PNGs (sized by height, aspect
from the PNG) and lays out all native text.

**Build order:** `python3 docs/build_assets.py` → `python3 docs/build_deck.py`.

Verified by rendering the `.pptx` to slide images via **LibreOffice headless** (LibreOffice + poppler
installed this session for visual QA — macOS has no Quick Look generator for `.pptx`). All six slides
were eyeballed; the only fix surfaced by rendering was a faint raster seam under downscaled tagline
text, resolved by switching the Title/Closing wordmarks to native text (see Deviations).

Numbers: 292 tests cited (per the prompt); where slides reference demo figures they use the **real
fork run** from `docs/demo-run-output.md` (entry notional 228.38, total coverage 12.51, payout 2.23
USDC bound by IL_CAP) — matching the frontend `?demo=true` view.

---

## 5. Recorded demo

- **URL:** https://www.youtube.com/watch?v=82_9mEh_POM
- **Runtime:** ~**3m 53s** (under the 5-minute target in spec §15).
- **Linked in:** `README.md` ("Demo video:") and the live dashboard context.
- Content follows `docs/demo-narrative.md`: the terminal segment (`RangeGuardDemo.s.sol`, fork +
  `vm.warp` 45-day lifecycle) and the coverage-report segment (the `?demo=true` dashboard view),
  with the Reactive-Network cross-chain automation as the differentiator.

---

## 6. Deviations from plan

1. **Title/Closing logos are native Calibri text, not embedded `logo-full.svg` / `logo-standalone.svg`
   images.** Rasterizing the full SVGs (text included) and downscaling them in the renderer produced a
   faint full-width seam under the tagline/wordmark. Composing the lockups from the shield **icon**
   (raster) + **native pptx text** is crisper, on-brand (Calibri), and artifact-free. The full SVG
   lockups remain as standalone brand assets in `docs/assets/`.
2. **Light logo variants** (`logo-full-light.svg`, `logo-standalone-light.svg`) were added on request
   mid-Phase-1 — not in the original four-variant spec.
3. **Reactive partner logo** came as a `reactive | Dev` docs lockup; the `| Dev` suffix is cropped for
   a clean "Powered by" badge. Uniswap's official mark is `#F50DB4` (current brand pink), distinct
   from the deck's gradient-stroke `#FF007A`.
4. **Tooling installed for QA:** LibreOffice + poppler (for `.pptx`→image rendering). Earlier in the
   session, the pptx `SKILL.md` referenced by the original 9-slide prompt (`/mnt/skills/public/pptx/`)
   did not exist on this machine, so the deck was built directly with `python-pptx` (pip-installed).
5. **Center bar height** rendered at ~80% of shield height rather than a literal 85% (a literal 85%
   poked through the shield's rounded top); reads as intended.
6. **Demo runtime** came in at ~3m 53s, comfortably under the 5-minute target.

---

## 7. Carry-ins / remaining

- **Next:** coverage + gas snapshot (`forge coverage` / `forge snapshot`), then the full README
  write-up. The demo is recorded + linked and the slides are done.
- Deck and logos are reproducible from source via the two builders; PNGs in `docs/assets/png/` are
  committed so the deck rebuilds without needing `qlmanage`/macOS.
