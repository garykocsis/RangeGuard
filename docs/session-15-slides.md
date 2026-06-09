# Session 15 — Google Slides Demo Deck

**Date:** 2026-06-08
**Branch:** `feat/slides`
**Deliverable:** `docs/RangeGuard-Demo-Deck.pptx` (+ reproducible builders `docs/build_deck.py`,
`docs/build_assets.py`) + logo assets in `docs/assets/`

---

## Rebuild (v2) — logo + 6-slide deck

The deck was rebuilt from the original 9-slide version (recorded further below) down to a tighter
**6-slide** narrative, and a project **logo** was designed. Two phases:

### Phase 1 — RangeGuard logo (`docs/assets/`)
A custom mark: a classic shield (gradient stroke `#FF007A → #9B59B6`, transparent fill) wrapping
three green (`#00d395`) vertical bars — a "range" bar-chart guarded by a shield. Bars: left 60% /
center 85% / right 45% height, 12%-width, 8% gaps, centered + bottom-aligned. Eight SVG files:
- `logo-icon.svg` (64×64) · `favicon.svg` (32×32, 2px stroke, simplified)
- `logo-standalone.svg` (300×64, icon + "RangeGuard" white) · `logo-standalone-light.svg` (dark text)
- `logo-full.svg` (360×140, icon + name + tagline, white) · `logo-full-light.svg` (dark text `#0f1117`,
  tagline `#4a5568`)
- The light variants were added on request for light-background placements.

Partner logos fetched from official sources and saved to `docs/assets/`:
- `uniswap-logo.svg` — the pink unicorn mark (`#F50DB4`), from cryptologos.cc.
- `reactive-logo.svg` / `reactive-logo-dark.svg` — the Reactive wordmark, from
  `dev.reactive.network/img/rn-docs-logo-{white,black}.svg`. (The asset is a `reactive | Dev`
  lockup; for the embed PNG the `| Dev` suffix is cropped off — see below.)

### Phase 2 — 6-slide deck
Structural changes from v1: removed the two IL-explanation slides (judges know IL), the demo
transition, and the coverage-report transition; added a **Title** slide. New order:
1. **Title** — `logo-full` centered + "Gary Kocsis / Uniswap Hook Incubator" + "Built on
   [Uniswap] · Powered by [Reactive]" partner row.
2. **The Solution** — headline + 5 two-line bullets + tagline.
3. **Economic Flywheel** — two-row flow **loop** (NOT circular): row 1 L→R, down arrow, row 2 R→L,
   up arrow back to start; the two buffer boxes accent-bordered.
4. **Five Pillars** — Pillar 4 (LP Transparency ★) highlighted.
5. **Code Walkthrough** — 6-box lifecycle (all accent-bordered, same color) + two amber callouts.
6. **Closing** — `logo-standalone` top center + ✓ bullets + beneficiary table + partner row +
   dashboard/GitHub links + 292-tests footer.
Logo placement: `logo-icon` top-left (24px, beside the section label) on slides 2–5; full speaker
notes (incl. verbal transitions + IDE narration) carried on every slide, per the v2 prompt.

### Rasterization note (important for reproducibility)
python-pptx **cannot embed SVG**, and the only local renderer (macOS `qlmanage`) composites SVGs
on an opaque **white** background. Since every logo sits on the flat `#0f1117` slide background,
`docs/build_assets.py` re-renders each SVG with a matching navy background rect (seamless on-slide)
at 2000px, auto-crops `qlmanage`'s white padding to a tight content box, and writes PNGs to
`docs/assets/png/`. `build_deck.py` embeds those PNGs sized by height (aspect from the PNG). The
Reactive PNG is right-cropped (`keep_left=0.685`) to drop the `| Dev` suffix.
**Build order:** `python3 docs/build_assets.py` → `python3 docs/build_deck.py`.

### Verification
Structure validated (6 slides, 13.333×7.5, logos embedded on the right slides, notes on all).
Rendered to slide images via LibreOffice headless for visual QA (LibreOffice installed this
session; macOS has no Quick Look generator for `.pptx`).

---

## Original v1 record — 9-slide deck (superseded by the rebuild above)

A complete 9-slide presentation as a `.pptx` file that imports directly into Google Slides.

- **Format:** 16:9 widescreen (13.333" × 7.5"), Calibri throughout (best Google-Slides import
  fidelity), built with `python-pptx` 1.0.2.
- **Design system (applied to all 9 slides):**
  | role | hex |
  |---|---|
  | background (dark navy) | `#0f1117` |
  | primary text (white) | `#ffffff` |
  | accent (Uniswap green) | `#00d395` |
  | secondary text (slate) | `#94a3b8` |
  | warning / amber | `#f59e0b` |
  | danger / red | `#ef4444` |
  | card / panel bg | `#1e2433` |
- **Speaker notes:** every slide carries its full speaker notes (including verbal transitions and
  IDE/browser narration) in the notes panel.

### Slide inventory
1. **The Problem — Statement + Mechanism:** headline, subtitle, divider, four bullets.
2. **The Problem — The Math:** Day-0 banner, three-column HODL / LP-Withdrawal / IL comparison
   ($3,500 / $3,354 / −$146, −4.2%), red net-loss callout (−$134), concentrated-liquidity callout.
3. **The Solution — Introduction:** "earned, capped, on-chain claim" headline, A/365F subtitle,
   tagline.
4. **The Solution — Economic Flywheel:** six-box circular flow (LPs → traders → fees → buffer →
   claims → protected → loop), boxes 4 & 5 accent-bordered.
5. **The Solution — Five Pillars:** numbered list, Pillar 4 (LP Transparency ★) highlighted.
6. **Code Walkthrough — Transition:** six-box horizontal lifecycle (LP Deposits → `_accrue()` →
   `afterSwap()` → `_computeIL()` → `_computePayout()` → ClaimSettled), two amber callouts.
7. **Demo Script — Transition:** Setup / Lifecycle / Settlement columns + full-width Reactive
   Network callout.
8. **Coverage Report — Transition:** Traditional vs RangeGuard columns + event→report-row mapping
   table.
9. **Closing:** tagline, four ✓ bullets, beneficiary table, links/badges, 292-tests footer.

### Source-of-truth decisions
- Content follows the opening prompt's slide spec **verbatim**. A handful of fragments in that
  prompt were corrupted/truncated; these were reconstructed from `docs/demo-narrative.md` and
  spec §14: "Net loss vs HODL: −$134", the concentrated-liquidity callout, the `_computeIL()`
  lifecycle box, the `PositionRegistered → Entry snapshot` table row, and the GitHub /
  live-dashboard closing lines.
- Where slides cite demo figures, the **real fork run** (`docs/demo-run-output.md`) was used: entry
  notional 228.38 USDC, total coverage 12.51 USDC, payout 2.23 USDC bound by `IL_CAP`, buffer
  ~10,000 USDC. (spec §14's narrative arc uses different *illustrative* numbers — 10,000 entry /
  43.75 payout — but the deck matches the actual run, consistent with the frontend `?demo=true`
  view.) Test count: **292**, as stated in the prompt.

### Build / verify notes
- Regenerate any time with `python3 docs/build_deck.py` (rewrites the `.pptx` in place).
- The pptx `SKILL.md` referenced in the prompt lives at a sandbox-only path (`/mnt/skills/...`) that
  is **not present on this machine**; the deck was built directly with `python-pptx`, which had to
  be `pip install`-ed.
- No LibreOffice/`soffice` available locally, so the deck was validated **structurally** (9 slides,
  correct 13.333×7.5 dimensions, notes present on every slide) rather than by visual render. Open
  once in Google Slides to eyeball before recording.

---

## Opening prompt (verbatim)

> RangeGuard — Google Slides Deck
> Branch: feat/slides (create this branch before starting)
> Mandatory first steps:
>
> Read docs/demo-narrative.md
> Read docs/demo-run-output.md
> Read spec.md Section 14 (demo configuration)
> Confirm understanding before writing any code
>
> Task: Build a complete Google Slides presentation as a .pptx file that can be imported directly into Google Slides. Save it to docs/RangeGuard-Demo-Deck.pptx.
>
> Design system — apply consistently across all 9 slides:
> Background:       #0f1117  (dark navy)
> Primary text:     #ffffff  (white)
> Accent color:     #00d395  (Uniswap green)
> Secondary text:   #94a3b8  (slate gray)
> Warning/amber:    #f59e0b  (amber)
> Danger/red:       #ef4444  (red)
> Card/panel bg:    #1e2433  (slightly lighter than background)
> Font — headlines: Inter or Calibri Bold
> Font — body:      Inter or Calibri Regular
> Font — code:      Courier New or Consolas
> Slide dimensions: 16:9 widescreen (13.33" x 7.5")
>
> Slide 1 — The Problem: Statement + Mechanism
> Layout: label topine centered top, subtitle below headline, divider line, four bullets bottom half.
> [Label — small caps, accent color, top left]
> THE PROBLEM
>
> [Headline — large, white, centered]
> LPs Can Lose Value
> Compared to Simply Holding
>
> [Subtitle — slate gray, centered]
> Impermanent loss is the gap between
> HODL value and LP withdrawal value
>
> [Horizontal divider line — accent color]
>
> [Section intro — small, accent color]
> Impermanent loss happens when:
>
> [Four bullets — white, left aligned]
> - An LP deposits two assets — for example ETH + USDC
> - The price of ETH moves
> - The AMM automatically rebalances the LP's inventory
> - At withdrawal, the LP receives a token mix
>   worth less than simply holding
> Speaker notes:
>
> "Liquidity providers earn swap fees — but they also take on a hidden risk: impermanent loss. When an LP deposits ETH and USDC into an AMM, they are no longer simply holding those assets. As price moves, the pool automatically rebalances their inventory. At withdrawal, the LP may receive a token mix wf they had simply held. In options terms, LPs are implicitly selling volatility — collecting fee premium but bearing downside when the market moves against them."
>
> Slide 2 — The Problem: The Math
> Layout: label top left, banner centered top, three-column comparison middle, two callout boxes bottom.
> [Label — small caps, accent color, top left]
> THE PROBLEM
>
> [Banner — card bg, centered, rounded corners]
> 📍 Day 0: 1 ETH = $2,000 USDC
>    Deposit: 1 ETH + 2,000 USDC = $4,000 total
>
> [Three columns — equal width, middle of slide]
>
> Column 1 — HODL:
> Header: HODL
> ────────────
> ETH drops to $1,500
>
> Value: $3,500
>
> Column 2 — LP Withdrawal:
> Header: LP Withdrawal
> ────────────
> Pool rebalanced position
> Fees included
>
> Value: $3,354
>
> Column 3 — Impermanent Loss:
> Header: Impermanent Loss
> ────────────
>
>
> Gap: -$146
>      (-4.2%)
>
> [Red callout box — bottom left]
> ⚠ Swap fees earned:  +$12
>   Impermanent loss:  -$146
>   Net loss vs HODL:  -$13oncentrated liquidity:
>    Tighter ranges = more fees
>    AND amplified IL exposure
>    The tradeoff is unavoidable — until now.
> Speaker notes:
>
> "Here's a concrete example. ETH starts at $2,000. You deposit 1 ETH and 2,000 USDC — $4,000 total. The price drops to $1,500. If you had simply held, your portfolio would be worth $3,500. But as an LP, the pool rebalanced your position as the price moved. Your withdrawal value — including fees — is only $3,354. You earned $12 in swap fees but lost $146 to impermanent loss. Net loss: $134. And in Uniswap v4's concentrated liquidity model, tighter ranges amplify this effect — more fees, but more IL exposure."
>
> Verbal transition (add to speaker notes):
>
> "The next question is: can that downside be measured, covered, and paid out — directly from the pool itself?"
>
> Slide 3 — The Solution: Introduction
> Layout: label top left, large headline centered, subtitle fragments below, tagline at bottom accent color.
> [Label — small caps, accent color, top left]
> THE SOe — large, white, centered]
> RangeGuard turns impermanent loss
> into an earned, capped, on-chain claim.
>
> [Subtitle — three parallel lines, slate gray, centered]
> Earned over time.
> Funded by swap activity.
> Settled automatically.
> Accrual calculated using Actual/365 Fixed —
> a standard financial day-count convention.
>
> [Tagline — accent color, centered, bottom]
> "Protect your liquidity. Guard your range."
> Speaker notes:
>
> "RangeGuard is a Uniswap v4 hook that provides native, on-chain impermanent loss coverage for liquidity providers. No premium to pay upfront. No claim form. No off-chain infrastructure. Coverage is built directly into the pool. The day-count basis is important because this is not an arbitrary reward counter — it is coverage accrual, calculated using the same Actual/365 Fixed convention used in fixed-income finance. LPs can estimate their coverage before depositing, and anyone can verify every accrual event."
>
> Slide 4 — The Solution: Economic Flywheel
> Layout: label top left, headline topcular flow diagram center, single accent line bottom.
> [Label — small caps, accent color, top left]
> THE SOLUTION
>
> [Headline — white, centered]
> Self-Funding by Design
>
> [Circular flow diagram — center of slide]
> Use six boxes arranged in a circle with arrows:
>
> Box 1: "LPs provide liquidity"
>   ↓
> Box 2: "Traders use the pool"
>   ↓
> Box 3: "Swaps generate fees"
>   ↓
> Box 4: "A small portion funds the buffer"
>   ↓
> Box 5: "Buffer pays capped IL claims"
>   ↓
> Box 6: "LPs are protected"
>   ↑ (arrow loops back to Box 1)
>
> All boxes: card bg (#1e2433), white text, accent color arrows
> Box 4 and Box 5: highlight with accent color border
>
> [Single line — accent color, centered, bottom]
> Swap activity funds the buffer that protects LPs.
> Speaker notes:
>
> "The economics are self-sustaining. LPs provide liquidity, traders use the pool, swaps generate fees, and a small portion of every fee — the buffer slice — funds the coverage buffer. When a position closes, the buffer pays the capped IL claim. The buffer grows fry that LP liquidity enables. No external capital required."
>
> Slide 5 — The Solution: Five Pillars
> Layout: label top left, headline top center, five numbered items center, accent line bottom.
> [Label — small caps, accent color, top left]
> THE SOLUTION
>
> [Headline — white, centered]
> How RangeGuard Works: Five Pillars
>
> [Five numbered items — left aligned, spaced evenly]
>
> 1. Accrual Gating
>    Coverage accrues only while the position is in range
>
> 2. Buffer Funding
>    A portion of every swap fee funds the coverage buffer
>
> 3. Claim Settlement
>    IL computed and paid automatically on withdrawal
>    Payout = min(covered IL, earned coverage, buffer cap)
>
> 4. LP Transparency  ★
>    A verifiable, day-by-day coverage report —
>    built entirely from on-chain events
>    [Item 4 highlighted — accent color border or background]
>
> 5. Pool Configuration
>    Immutable parameters set once at pool initialization
>
> [Bottom line — accent color, centered]
> Every pillar is enforced on-chain. No off-chain assumptions.
> Speaker nrd is built on five pillars. Accrual gating — coverage only earns while in range. Buffer funding — every swap contributes automatically. Claim settlement — IL is computed and paid in the same withdrawal transaction, capped by three limits: covered IL, earned coverage, and buffer capacity. LP transparency — the key differentiator — a verifiable day-by-day coverage statement from pure on-chain events. And pool configuration — immutable parameters, so LPs always know what they signed up for."
>
> Verbal transition (add to speaker notes):
>
> "Let me show you the three core functions that make this work."
>
> Slide 6 — Code Walkthrough: Transition
> Layout: label top left, headline top center, horizontal lifecycle flow middle, two amber callouts below, accent line bottom.
> [Label — small caps, accent color, top left]
> UNDER THE HOOD
>
> [Headline — white, centered]
> How Coverage Becomes a Claim
>
> [Horizontal lifecycle flow — center of slide]
> Six boxes connected by arrows left to right:
>
> LP Deposits → _accrcomputeIL() → _computePayout() → ClaimSettled
>
> Box styling: card bg, white text
> Arrow color: accent color
> _accrue() and _computePayout() boxes: accent color border (highlighted)
>
> [Two amber callout boxes — side by side below the flow]
>
> Left callout:
> ⚡ Swaps never iterate positions —
>    accrual is lazy and position-specific.
>    O(1) gas on every swap.
>
> Right callout:
> ⚡ Coverage uses Actual/365 Fixed
>    day-count convention —
>    the same standard used in
>    fixed-income finance.
>
> [Bottom line — accent color, centered]
> Four functions. One atomic lifecycle. All on-chain.
> Speaker notes:
>
> "Before jumping into the IDE, here's the core code path. When an LP deposits, the hook registers their position. Coverage is then updated through _accrue, which only adds coverage while the current tick is inside the LP's range — accrual is lazy and position-specific, so swaps never iterate positions. afterSwap funds the buffer from every trade. On withdrawal, _computeIL compares the HODL value against the actualue to get raw impermanent loss. Then _computePayout applies the three caps to determine the final claim. Let me start with _accrue — because that's the core engine for earned coverage."
>
> IDE narration (add to speaker notes):
>
> "_accrue: Range gate — coverage only accrues inside the LP's range. Year fraction uses the pool's immutable day-count basis — if the LP is in range for 15 actual days, they earn exactly 15/365 of the annual coverage amount. The day-count convention turns coverage from a black-box reward into an auditable financial accrual. _computePayout: Three caps applied in order — IL cap, earned coverage cap, buffer cap. Payout is the minimum of all three. The limiting factor is recorded so the LP knows exactly why they received what they received."
>
> Slide 7 — Demo Script: Transition
> Layout: label top left, headline top center, three columns middle, reactive callout below columns, slate gray note bottom.
> [Label — small caps, accent color, top left]
> LIVE DEMO
>
> [Headline — white, cenLP Lifecycle
> on Sepolia Testnet
>
> [Three columns — equal width]
>
> Column 1 — Setup:
> 📍 Setup
> ─────────────
> Live Sepolia hook
> Buffer seeded
> 10,000 USDC
>
> Column 2 — Lifecycle:
> 📈 Lifecycle
> ─────────────
> LP deposits
> In-range accrual
> Range transition
> out + back in
> Buffer self-funds
>
> Column 3 — Settlement:
> 💰 Settlement
> ─────────────
> Full withdrawal
> IL computed
> Three caps applied
> ClaimSettled
>
> [Reactive Network callout — accent color, full width, below columns]
> ⚡ Reactive Network (Lasna) monitors the hook autonomously
>    Range transitions detected cross-chain — no keepers
>    checkpointAndEmitOutOfRange fires automatically
>
> [Bottom line — slate gray, centered]
> Every event is a real on-chain transaction.
> Fork of live Sepolia state — vm.warp simulates 45 days.
> Speaker notes:
>
> "Let's see it in action. This is a 45-day LP lifecycle running against a fork of the live Sepolia deployment. As the position moves in and out usly. When the tick crosses the LP's range boundary, it detects the transition and fires a callback back to Sepolia — no keepers, no bots, no off-chain infrastructure. Every number you see comes from the actual hook contract. Let's run it."
>
> Slide 8 — Coverage Report: Transition
> Layout: label top left, headline top center, two-column comparison upper middle, event mapping table lower middle, accent line bottom.
> [Label — small caps, accent color, top left]
> THE KEY DIFFERENTIATOR
>
> [Headline — white, centered]
> Every LP Gets a Verifiable
> Coverage Statement
>
> [Two columns — upper middle]
>
> Column 1 — Traditional:
> 📋 Traditional
> ─────────────
> Off-chain records
> Trust the platform
> Opaque calculations
> No breakdown
>
> Column 2 — RangeGuard:
> 🔍 RangeGuard
> ─────────────
> Pure on-chain events
> Verify yourself
> Every row auditable
> LimitingFactor shown
>
> [Event mapping table — lower middle, card bg]
> Event                  →   Coverage Report Row
> ───�hot (notional, APR, day-count basis)
> AccrualUpdated         →   Each accrual period (dt, delta, isInRange)
> PositionOutOfRange     →   Coverage paused (Reactive Network detected)
> PositionBackInRange    →   Coverage resumed (Reactive Network detected)
> ClaimSettled           →   Final settlement (IL, payout, limitingFactor)
>
> [Bottom line — accent color, centered]
> No off-chain assumptions. Fully verifiable.
> Built on Reactive Network cross-chain automation.
> Speaker notes:
>
> "This is the key differentiator. Every LP gets a verifiable, day-by-day coverage statement — built entirely from on-chain events. Every row maps to a real transaction. The accrual periods show whether the position was in range. Because the accrual basis is explicit — the day-count convention, the APR, the entry notional — every row can be independently recomputed from the event data. It's not a black box. The range transitions were detected autonomously by the Reactive Network running on Lasna. And the settlement row shows exacs the binding constraint. Let me show you."
>
> Browser narration (add to speaker notes):
>
> "Demo mode: Here's the full 45-day lifecycle. Every row maps to a real on-chain event. Accrual periods show in range, earning coverage. The out-of-range pause detected by the Reactive Network. Resumption. Final settlement — IL cap was the binding constraint, payout 2.23 USDC. Each accrual row shows elapsed time, delta earned using A/365F, and the in-range flag. The day-count convention makes this auditable — not a black box. Live mode: Reading real events from Sepolia right now. Every LP in this pool can pull up their own verifiable coverage statement. Buffer at 10,000 USDC, growing from real swap fees. Self-sustaining by design."
>
> Verbal transition (add to speaker notes):
>
> "RangeGuard makes IL coverage predictable, auditable, and comparable — because the day-count convention turns coverage from a black-box reward into an auditable financial accrual."
>
> Slide 9 — Closing
> Layout: tagline top center, four bullets udle, beneficiary table lower middle, closing line accent, divider, links and badges bottom.
> [Tagline — large, accent color, centered, top]
> "Protect your liquidity. Guard your range."
>
> [Four bullets — white, left aligned, upper middle]
> ✓ Native IL coverage — built into the pool, not bolted on
> ✓ Self-funding buffer — swap fees cover the claims
> ✓ Capped payouts — actuarially sound, buffer protected
> ✓ Fully auditable — every accrual verifiable on-chain
>
> [Beneficiary table — card bg, center]
> Who Benefits          Why It Matters
> ─────────────────     ──────────────────────────────────────
> Passive LPs           Downside protection without complex hedging
> Protocols / DAOs      Deeper liquidity without reliance on emissions
> Uniswap Ecosystem     Durable liquidity, tighter spreads, better execution
>
> [Closing line — large, accent color, centered]
> Earned over time. Funded by swaps. SettlHub
> github.com/garykocsis/RangeGuard
>
> [Network badges — centered, slate gray]
> Built on Uniswap v4  ·  Powered by Reactive Network  ·  Deployed on Sepolia
>
> [Very bottom — small, slate gray]
> 292 tests passing  ·  Fuzz tested  ·  Invariant tested
> Speaker notes:
>
> "RangeGuard proves that impermanent loss coverage doesn't require a separate protocol, an oracle, or off-chain infrastructure. It's native — built directly into the pool, funded by the same swap activity it protects against, capped to keep the buffer solvent, and settled automatically on withdrawal. The primary beneficiaries are passive and semi-passive LPs — they get downside protection without complex hedging strategies. But the impact extends to protocols and DAOs that need sticky liquidity without relying on token emissions, and to the broader Uniswap ecosystem through deeper pools, tighter spreads, and better execution. The coverage statement is auditable by anyone, recomputable from on-chain events, and expressed in a standard financi convention. Earned over time. Funded by swaps. Settled on-chain. The live dashboard is at range-guard.vercel.app. Full source and 292 passing tests on GitHub. Thank you."
>
> Technical requirements for Opus:
>
> Read /mnt/skills/public/pptx/SKILL.md before writing any code
> Save output to docs/RangeGuard-Demo-Deck.pptx
> Use python-pptx to build the file
> Apply the design system consistently across all 9 slides
> Add all speaker notes to the notes panel of each slide
> Ensure slide dimensions are 16:9 widescreen (13.33" x 7.5")
> Use Calibri as the font family (best compatibility with Google Slides import)
> After generating, present the file for download
>
> Session closer:
>
> Commit docs/RangeGuard-Demo-Deck.pptx on branch feat/slides
> Update project-status.md — tick slides checkbox
> Update CLAUDE.md — current session state
> Generate docs/session-15-slides.md with the full opening prompt verbatim
