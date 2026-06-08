#!/usr/bin/env python3
"""Build RangeGuard-Demo-Deck.pptx — 9-slide Google-Slides-ready deck.

Design system (RangeGuard demo deck):
  background  #0f1117   primary text #ffffff   accent #00d395
  secondary   #94a3b8   amber        #f59e0b   danger #ef4444
  card bg     #1e2433
Font: Calibri (Google Slides import compatibility). 16:9 widescreen.
"""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
from pptx.oxml.ns import qn

# ---------------------------------------------------------------- palette
BG       = RGBColor(0x0F, 0x11, 0x17)
WHITE    = RGBColor(0xFF, 0xFF, 0xFF)
ACCENT   = RGBColor(0x00, 0xD3, 0x95)
SLATE    = RGBColor(0x94, 0xA3, 0xB8)
AMBER    = RGBColor(0xF5, 0x9E, 0x0B)
DANGER   = RGBColor(0xEF, 0x44, 0x44)
CARD     = RGBColor(0x1E, 0x24, 0x33)

HEAD_FONT = "Calibri"
BODY_FONT = "Calibri"
CODE_FONT = "Consolas"

EMU_IN = 914400
SW, SH = 13.333, 7.5

prs = Presentation()
prs.slide_width  = Emu(int(SW * EMU_IN))
prs.slide_height = Emu(int(SH * EMU_IN))
BLANK = prs.slide_layouts[6]


# ---------------------------------------------------------------- helpers
def add_slide():
    s = prs.slides.add_slide(BLANK)
    r = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, prs.slide_width, prs.slide_height)
    r.fill.solid(); r.fill.fore_color.rgb = BG
    r.line.fill.background()
    r.shadow.inherit = False
    # send background to back
    sp = r._element
    sp.getparent().remove(sp)
    s.shapes._spTree.insert(2, sp)
    return s


def _set_run(run, text, size, color, bold=False, font=BODY_FONT, italic=False):
    run.text = text
    f = run.font
    f.size = Pt(size); f.bold = bold; f.italic = italic
    f.name = font
    f.color.rgb = color


def txt(slide, x, y, w, h, lines, align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP,
        wrap=True):
    """lines: list of paragraphs; each paragraph is list of run dicts or a single dict.
       run dict: {t, size, color, bold, font, italic, space_before, space_after, line_spacing}
    """
    tb = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = wrap
    tf.vertical_anchor = anchor
    tf.margin_left = 0; tf.margin_right = 0
    tf.margin_top = 0; tf.margin_bottom = 0
    for i, para in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        if isinstance(para, dict):
            para = [para]
        meta = para[0] if para else {}
        if meta.get("space_before") is not None:
            p.space_before = Pt(meta["space_before"])
        if meta.get("space_after") is not None:
            p.space_after = Pt(meta["space_after"])
        if meta.get("line_spacing") is not None:
            p.line_spacing = meta["line_spacing"]
        for rd in para:
            r = p.add_run()
            _set_run(r, rd["t"], rd.get("size", 18), rd.get("color", WHITE),
                     rd.get("bold", False), rd.get("font", BODY_FONT),
                     rd.get("italic", False))
    return tb


def card(slide, x, y, w, h, fill=CARD, border=None, border_w=1.5, radius=0.08):
    sh = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                                Inches(x), Inches(y), Inches(w), Inches(h))
    sh.fill.solid(); sh.fill.fore_color.rgb = fill
    if border is None:
        sh.line.fill.background()
    else:
        sh.line.color.rgb = border; sh.line.width = Pt(border_w)
    sh.shadow.inherit = False
    # adjust corner radius
    try:
        sh.adjustments[0] = radius
    except Exception:
        pass
    return sh


def line(slide, x, y, w, color=ACCENT, weight=2.5):
    sh = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE,
                                Inches(x), Inches(y), Inches(w), Inches(weight / 72.0))
    sh.fill.solid(); sh.fill.fore_color.rgb = color
    sh.line.fill.background(); sh.shadow.inherit = False
    return sh


def arrow(slide, x, y, w, h, color=ACCENT, shape=MSO_SHAPE.RIGHT_ARROW):
    sh = slide.shapes.add_shape(shape, Inches(x), Inches(y), Inches(w), Inches(h))
    sh.fill.solid(); sh.fill.fore_color.rgb = color
    sh.line.fill.background(); sh.shadow.inherit = False
    return sh


def label(slide, text):
    txt(slide, 0.6, 0.42, 5.0, 0.4,
        [[{"t": text, "size": 13, "color": ACCENT, "bold": True, "font": HEAD_FONT}]])


def notes(slide, text):
    slide.notes_slide.notes_text_frame.text = text


def centerbox(slide, x, y, w, h, paras, anchor=MSO_ANCHOR.MIDDLE):
    return txt(slide, x, y, w, h, paras, align=PP_ALIGN.CENTER, anchor=anchor)


# ================================================================ SLIDE 1
s = add_slide()
label(s, "THE PROBLEM")
centerbox(s, 1.0, 1.05, 11.33, 1.55, [
    [{"t": "LPs Can Lose Value", "size": 46, "color": WHITE, "bold": True, "font": HEAD_FONT}],
    [{"t": "Compared to Simply Holding", "size": 46, "color": WHITE, "bold": True, "font": HEAD_FONT}],
], anchor=MSO_ANCHOR.TOP)
centerbox(s, 1.5, 2.65, 10.33, 0.9, [
    [{"t": "Impermanent loss is the gap between", "size": 19, "color": SLATE}],
    [{"t": "HODL value and LP withdrawal value", "size": 19, "color": SLATE}],
], anchor=MSO_ANCHOR.TOP)
line(s, 4.665, 3.78, 4.0)
txt(s, 1.4, 4.12, 10.5, 0.4,
    [[{"t": "Impermanent loss happens when:", "size": 16, "color": ACCENT, "bold": True}]])
bullets = [
    "An LP deposits two assets — for example ETH + USDC",
    "The price of ETH moves",
    "The AMM automatically rebalances the LP's inventory",
    "At withdrawal, the LP receives a token mix worth less than simply holding",
]
txt(s, 1.4, 4.62, 10.5, 2.4,
    [[{"t": "•  " + b, "size": 19, "color": WHITE, "space_after": 9}] for b in bullets])
notes(s,
"Liquidity providers earn swap fees — but they also take on a hidden risk: impermanent loss. "
"When an LP deposits ETH and USDC into an AMM, they are no longer simply holding those assets. "
"As price moves, the pool automatically rebalances their inventory. At withdrawal, the LP may "
"receive a token mix worth less than if they had simply held. In options terms, LPs are "
"implicitly selling volatility — collecting fee premium but bearing downside when the market "
"moves against them.")

# ================================================================ SLIDE 2
s = add_slide()
label(s, "THE PROBLEM")
# banner
card(s, 2.665, 0.95, 8.0, 0.95, fill=CARD)
centerbox(s, 2.665, 0.95, 8.0, 0.95, [
    [{"t": "📍 Day 0:  1 ETH = $2,000 USDC", "size": 18, "color": WHITE, "bold": True}],
    [{"t": "Deposit: 1 ETH + 2,000 USDC = $4,000 total", "size": 15, "color": SLATE}],
])
# three columns
cols = [
    ("HODL", WHITE, [("ETH drops to $1,500", SLATE), ("", SLATE)],
     "Value: $3,500", WHITE),
    ("LP Withdrawal", WHITE, [("Pool rebalanced position", SLATE), ("Fees included", SLATE)],
     "Value: $3,354", WHITE),
    ("Impermanent Loss", AMBER, [("", SLATE), ("", SLATE)],
     "Gap: -$146", DANGER),
]
cx = 0.85; cw = 3.7; gap = 0.3
for i, (hdr, hc, mid, val, vc) in enumerate(cols):
    x = cx + i * (cw + gap)
    card(s, x, 2.2, cw, 2.55, fill=CARD)
    centerbox(s, x, 2.4, cw, 0.5,
              [[{"t": hdr, "size": 18, "color": hc, "bold": True}]], anchor=MSO_ANCHOR.TOP)
    line(s, x + 0.6, 2.92, cw - 1.2, color=ACCENT, weight=1.5)
    midparas = [[{"t": m or " ", "size": 14, "color": c, "space_after": 4}] for m, c in mid]
    txt(s, x + 0.3, 3.15, cw - 0.6, 0.9, midparas, align=PP_ALIGN.CENTER)
    sub = "(-4.2%)" if "Gap" in val else ""
    valparas = [[{"t": val, "size": 21, "color": vc, "bold": True}]]
    if sub:
        valparas.append([{"t": sub, "size": 14, "color": vc, "space_before": 2}])
    txt(s, x + 0.2, 4.0, cw - 0.4, 0.7, valparas, align=PP_ALIGN.CENTER)
# red callout bottom left
card(s, 0.85, 5.1, 5.6, 1.7, fill=CARD, border=DANGER, border_w=2)
txt(s, 1.15, 5.35, 5.0, 1.3, [
    [{"t": "⚠  Swap fees earned:   +$12", "size": 16, "color": WHITE, "bold": True, "space_after": 5}],
    [{"t": "Impermanent loss:    -$146", "size": 16, "color": WHITE, "space_after": 5}],
    [{"t": "Net loss vs HODL:    -$134", "size": 16, "color": DANGER, "bold": True}],
])
# accent callout bottom right
card(s, 6.75, 5.1, 5.7, 1.7, fill=CARD, border=ACCENT, border_w=2)
txt(s, 7.05, 5.3, 5.1, 1.4, [
    [{"t": "Concentrated liquidity:", "size": 16, "color": ACCENT, "bold": True, "space_after": 4}],
    [{"t": "Tighter ranges = more fees", "size": 15, "color": WHITE, "space_after": 3}],
    [{"t": "AND amplified IL exposure", "size": 15, "color": WHITE, "space_after": 6}],
    [{"t": "The tradeoff is unavoidable — until now.", "size": 14, "color": SLATE, "italic": True}],
])
notes(s,
"Here's a concrete example. ETH starts at $2,000. You deposit 1 ETH and 2,000 USDC — $4,000 "
"total. The price drops to $1,500. If you had simply held, your portfolio would be worth $3,500. "
"But as an LP, the pool rebalanced your position as the price moved. Your withdrawal value — "
"including fees — is only $3,354. You earned $12 in swap fees but lost $146 to impermanent loss. "
"Net loss: $134. And in Uniswap v4's concentrated liquidity model, tighter ranges amplify this "
"effect — more fees, but more IL exposure.\n\n"
"Verbal transition: The next question is — can that downside be measured, covered, and paid out, "
"directly from the pool itself?")

# ================================================================ SLIDE 3
s = add_slide()
label(s, "THE SOLUTION")
centerbox(s, 1.0, 1.55, 11.33, 1.5, [
    [{"t": "RangeGuard turns impermanent loss", "size": 36, "color": WHITE, "bold": True, "font": HEAD_FONT}],
    [{"t": "into an earned, capped, on-chain claim.", "size": 36, "color": WHITE, "bold": True, "font": HEAD_FONT}],
], anchor=MSO_ANCHOR.TOP)
centerbox(s, 1.0, 3.35, 11.33, 1.6, [
    [{"t": "Earned over time.", "size": 22, "color": SLATE, "space_after": 4}],
    [{"t": "Funded by swap activity.", "size": 22, "color": SLATE, "space_after": 4}],
    [{"t": "Settled automatically.", "size": 22, "color": SLATE, "space_after": 14}],
    [{"t": "Accrual calculated using Actual/365 Fixed —", "size": 17, "color": SLATE, "italic": True}],
    [{"t": "a standard financial day-count convention.", "size": 17, "color": SLATE, "italic": True}],
], anchor=MSO_ANCHOR.TOP)
centerbox(s, 1.0, 6.2, 11.33, 0.7,
          [[{"t": "“Protect your liquidity. Guard your range.”",
             "size": 24, "color": ACCENT, "bold": True, "italic": True}]])
notes(s,
"RangeGuard is a Uniswap v4 hook that provides native, on-chain impermanent loss coverage for "
"liquidity providers. No premium to pay upfront. No claim form. No off-chain infrastructure. "
"Coverage is built directly into the pool. The day-count basis is important because this is not "
"an arbitrary reward counter — it is coverage accrual, calculated using the same Actual/365 "
"Fixed convention used in fixed-income finance. LPs can estimate their coverage before "
"depositing, and anyone can verify every accrual event.")

# ================================================================ SLIDE 4
s = add_slide()
label(s, "THE SOLUTION")
centerbox(s, 1.0, 0.85, 11.33, 0.7,
          [[{"t": "Self-Funding by Design", "size": 32, "color": WHITE, "bold": True, "font": HEAD_FONT}]],
          anchor=MSO_ANCHOR.TOP)
# circular flow: 6 boxes around an ellipse
flow = [
    ("LPs provide\nliquidity", False),
    ("Traders use\nthe pool", False),
    ("Swaps generate\nfees", False),
    ("A small portion\nfunds the buffer", True),
    ("Buffer pays\ncapped IL claims", True),
    ("LPs are\nprotected", False),
]
import math
cxp, cyp = 6.665, 3.95   # center
rx, ry = 4.05, 1.75      # radius
bw, bh = 2.35, 0.95
positions = []
# place at angles starting top, clockwise
angles = [-90, -30, 30, 90, 150, 210]
for ang in angles:
    a = math.radians(ang)
    px = cxp + rx * math.cos(a) - bw / 2
    py = cyp + ry * math.sin(a) - bh / 2
    positions.append((px, py))
# arrows (between consecutive box centers) — draw simple chevrons near midpoints
for i in range(6):
    nx = (i + 1) % 6
    c1 = (positions[i][0] + bw / 2, positions[i][1] + bh / 2)
    c2 = (positions[nx][0] + bw / 2, positions[nx][1] + bh / 2)
    mx, my = (c1[0] + c2[0]) / 2, (c1[1] + c2[1]) / 2
    txt(s, mx - 0.35, my - 0.25, 0.7, 0.5,
        [[{"t": "→", "size": 26, "color": ACCENT, "bold": True}]],
        align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
for (text, hl), (px, py) in zip(flow, positions):
    bd = ACCENT if hl else None
    card(s, px, py, bw, bh, fill=CARD, border=bd, border_w=2)
    parts = text.split("\n")
    centerbox(s, px, py, bw, bh,
              [[{"t": p, "size": 14, "color": WHITE, "bold": hl}] for p in parts])
centerbox(s, 1.0, 6.65, 11.33, 0.55,
          [[{"t": "Swap activity funds the buffer that protects LPs.",
             "size": 19, "color": ACCENT, "bold": True}]])
notes(s,
"The economics are self-sustaining. LPs provide liquidity, traders use the pool, swaps generate "
"fees, and a small portion of every fee — the buffer slice — funds the coverage buffer. When a "
"position closes, the buffer pays the capped IL claim. The buffer grows from the very swap "
"activity that that LP liquidity enables. No external capital required.")

# ================================================================ SLIDE 5
s = add_slide()
label(s, "THE SOLUTION")
centerbox(s, 1.0, 0.8, 11.33, 0.7,
          [[{"t": "How RangeGuard Works: Five Pillars", "size": 30, "color": WHITE, "bold": True, "font": HEAD_FONT}]],
          anchor=MSO_ANCHOR.TOP)
pillars = [
    ("1", "Accrual Gating", ["Coverage accrues only while the position is in range"], False),
    ("2", "Buffer Funding", ["A portion of every swap fee funds the coverage buffer"], False),
    ("3", "Claim Settlement", ["IL computed and paid automatically on withdrawal",
                               "Payout = min(covered IL, earned coverage, buffer cap)"], False),
    ("4", "LP Transparency  ★", ["A verifiable, day-by-day coverage report —",
                                       "built entirely from on-chain events"], True),
    ("5", "Pool Configuration", ["Immutable parameters set once at pool initialization"], False),
]
y = 1.75
for num, title, body, hl in pillars:
    rowh = 0.78 + 0.26 * (len(body) - 1)
    if hl:
        card(s, 0.8, y - 0.08, 11.73, rowh + 0.12, fill=CARD, border=ACCENT, border_w=2)
    txt(s, 1.05, y, 0.7, rowh, [[{"t": num, "size": 26, "color": ACCENT, "bold": True}]],
        anchor=MSO_ANCHOR.TOP)
    paras = [[{"t": title, "size": 19, "color": WHITE, "bold": True, "space_after": 3}]]
    for b in body:
        paras.append([{"t": b, "size": 15, "color": SLATE, "space_after": 1}])
    txt(s, 1.75, y, 10.6, rowh, paras, anchor=MSO_ANCHOR.TOP)
    y += rowh + 0.16
centerbox(s, 1.0, 6.85, 11.33, 0.45,
          [[{"t": "Every pillar is enforced on-chain. No off-chain assumptions.",
             "size": 17, "color": ACCENT, "bold": True}]])
notes(s,
"RangeGuard is built on five pillars. Accrual gating — coverage only earns while in range. "
"Buffer funding — every swap contributes automatically. Claim settlement — IL is computed and "
"paid in the same withdrawal transaction, capped by three limits: covered IL, earned coverage, "
"and buffer capacity. LP transparency — the key differentiator — a verifiable day-by-day "
"coverage statement from pure on-chain events. And pool configuration — immutable parameters, so "
"LPs always know what they signed up for.\n\n"
"Verbal transition: Let me show you the three core functions that make this work.")

# ================================================================ SLIDE 6
s = add_slide()
label(s, "UNDER THE HOOD")
centerbox(s, 1.0, 0.8, 11.33, 0.7,
          [[{"t": "How Coverage Becomes a Claim", "size": 30, "color": WHITE, "bold": True, "font": HEAD_FONT}]],
          anchor=MSO_ANCHOR.TOP)
# horizontal lifecycle flow — 6 boxes
steps = [
    ("LP Deposits", False),
    ("_accrue()", True),
    ("afterSwap()", False),
    ("_computeIL()", False),
    ("_computePayout()", True),
    ("ClaimSettled", False),
]
n = len(steps)
fx = 0.55; fw = 1.78; fgap = (12.78 - 0.55 - n * fw) / (n - 1)
fy = 2.15; fh = 0.95
for i, (label_t, hl) in enumerate(steps):
    x = fx + i * (fw + fgap)
    bd = ACCENT if hl else None
    card(s, x, fy, fw, fh, fill=CARD, border=bd, border_w=2)
    centerbox(s, x, fy, fw, fh,
              [[{"t": label_t, "size": 13.5, "color": (ACCENT if hl else WHITE),
                 "bold": True, "font": CODE_FONT}]])
    if i < n - 1:
        ax = x + fw + (fgap - 0.4) / 2
        txt(s, ax, fy + fh/2 - 0.25, 0.5, 0.5,
            [[{"t": "→", "size": 24, "color": ACCENT, "bold": True}]],
            align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
# two amber callouts
card(s, 0.85, 3.85, 5.6, 1.9, fill=CARD, border=AMBER, border_w=2)
txt(s, 1.15, 4.1, 5.05, 1.45, [
    [{"t": "⚡  Swaps never iterate positions —", "size": 16, "color": AMBER, "bold": True, "space_after": 5}],
    [{"t": "accrual is lazy and position-specific.", "size": 15, "color": WHITE, "space_after": 4}],
    [{"t": "O(1) gas on every swap.", "size": 15, "color": WHITE, "bold": True}],
])
card(s, 6.75, 3.85, 5.7, 1.9, fill=CARD, border=AMBER, border_w=2)
txt(s, 7.05, 4.1, 5.15, 1.5, [
    [{"t": "⚡  Coverage uses Actual/365 Fixed", "size": 16, "color": AMBER, "bold": True, "space_after": 5}],
    [{"t": "day-count convention —", "size": 15, "color": WHITE, "space_after": 4}],
    [{"t": "the same standard used in", "size": 15, "color": WHITE, "space_after": 2}],
    [{"t": "fixed-income finance.", "size": 15, "color": WHITE, "bold": True}],
])
centerbox(s, 1.0, 6.35, 11.33, 0.5,
          [[{"t": "Four functions. One atomic lifecycle. All on-chain.",
             "size": 18, "color": ACCENT, "bold": True}]])
notes(s,
"Before jumping into the IDE, here's the core code path. When an LP deposits, the hook registers "
"their position. Coverage is then updated through _accrue, which only adds coverage while the "
"current tick is inside the LP's range — accrual is lazy and position-specific, so swaps never "
"iterate positions. afterSwap funds the buffer from every trade. On withdrawal, _computeIL "
"compares the HODL value against the actual withdrawal value to get raw impermanent loss. Then "
"_computePayout applies the three caps to determine the final claim. Let me start with _accrue — "
"because that's the core engine for earned coverage.\n\n"
"IDE narration — _accrue: Range gate — coverage only accrues inside the LP's range. Year "
"fraction uses the pool's immutable day-count basis — if the LP is in range for 15 actual days, "
"they earn exactly 15/365 of the annual coverage amount. The day-count convention turns coverage "
"from a black-box reward into an auditable financial accrual. _computePayout: Three caps applied "
"in order — IL cap, earned coverage cap, buffer cap. Payout is the minimum of all three. The "
"limiting factor is recorded so the LP knows exactly why they received what they received.")

# ================================================================ SLIDE 7
s = add_slide()
label(s, "LIVE DEMO")
centerbox(s, 1.0, 0.8, 11.33, 1.3, [
    [{"t": "A Complete LP Lifecycle", "size": 30, "color": WHITE, "bold": True, "font": HEAD_FONT}],
    [{"t": "on Sepolia Testnet", "size": 30, "color": WHITE, "bold": True, "font": HEAD_FONT}],
], anchor=MSO_ANCHOR.TOP)
demo_cols = [
    ("📍 Setup", ["Live Sepolia hook", "Buffer seeded", "10,000 USDC"]),
    ("📈 Lifecycle", ["LP deposits", "In-range accrual", "Range transition",
                      "out + back in", "Buffer self-funds"]),
    ("💰 Settlement", ["Full withdrawal", "IL computed", "Three caps applied", "ClaimSettled"]),
]
cw = 3.7; gap = 0.3; cx = 0.85; cy = 2.25; ch = 2.55
for i, (hdr, items) in enumerate(demo_cols):
    x = cx + i * (cw + gap)
    card(s, x, cy, cw, ch, fill=CARD)
    centerbox(s, x, cy + 0.18, cw, 0.45,
              [[{"t": hdr, "size": 18, "color": ACCENT, "bold": True}]], anchor=MSO_ANCHOR.TOP)
    line(s, x + 0.6, cy + 0.72, cw - 1.2, color=ACCENT, weight=1.5)
    paras = [[{"t": it, "size": 14.5, "color": WHITE, "space_after": 5}] for it in items]
    txt(s, x + 0.4, cy + 0.95, cw - 0.8, ch - 1.05, paras, align=PP_ALIGN.CENTER)
# reactive callout full width
card(s, 0.85, 5.05, 11.63, 1.25, fill=CARD, border=ACCENT, border_w=2)
txt(s, 1.2, 5.25, 11.0, 0.95, [
    [{"t": "⚡  Reactive Network (Lasna) monitors the hook autonomously",
      "size": 16, "color": ACCENT, "bold": True, "space_after": 3}],
    [{"t": "Range transitions detected cross-chain — no keepers", "size": 14.5, "color": WHITE, "space_after": 2}],
    [{"t": "checkpointAndEmitOutOfRange fires automatically", "size": 14.5, "color": WHITE, "font": CODE_FONT}],
])
centerbox(s, 1.0, 6.5, 11.33, 0.8, [
    [{"t": "Every event is a real on-chain transaction.", "size": 14.5, "color": SLATE, "space_after": 1}],
    [{"t": "Fork of live Sepolia state — vm.warp simulates 45 days.", "size": 14.5, "color": SLATE}],
])
notes(s,
"Let's see it in action. This is a 45-day LP lifecycle running against a fork of the live Sepolia "
"deployment. As the position moves in and out of range, the Reactive Network on Lasna monitors "
"the hook autonomously. When the tick crosses the LP's range boundary, it detects the transition "
"and fires a callback back to Sepolia — no keepers, no bots, no off-chain infrastructure. Every "
"number you see comes from the actual hook contract. Let's run it.")

# ================================================================ SLIDE 8
s = add_slide()
label(s, "THE KEY DIFFERENTIATOR")
centerbox(s, 1.0, 0.78, 11.33, 1.25, [
    [{"t": "Every LP Gets a Verifiable", "size": 29, "color": WHITE, "bold": True, "font": HEAD_FONT}],
    [{"t": "Coverage Statement", "size": 29, "color": WHITE, "bold": True, "font": HEAD_FONT}],
], anchor=MSO_ANCHOR.TOP)
# two columns
twocols = [
    ("📋 Traditional", ["Off-chain records", "Trust the platform",
                        "Opaque calculations", "No breakdown"], SLATE),
    ("🔍 RangeGuard", ["Pure on-chain events", "Verify yourself",
                       "Every row auditable", "LimitingFactor shown"], ACCENT),
]
cw = 5.55; gap = 0.5; cx = 0.9; cy = 2.05; ch = 2.0
for i, (hdr, items, hc) in enumerate(twocols):
    x = cx + i * (cw + gap)
    card(s, x, cy, cw, ch, fill=CARD)
    centerbox(s, x, cy + 0.15, cw, 0.42,
              [[{"t": hdr, "size": 17, "color": hc, "bold": True}]], anchor=MSO_ANCHOR.TOP)
    line(s, x + 0.7, cy + 0.62, cw - 1.4, color=hc, weight=1.5)
    txt(s, x + 0.5, cy + 0.8, cw - 1.0, ch - 0.9,
        [[{"t": it, "size": 14.5, "color": WHITE, "space_after": 4}] for it in items],
        align=PP_ALIGN.CENTER)
# event mapping table
ty = 4.25
card(s, 0.9, ty, 11.53, 2.05, fill=CARD)
rows = [
    ("Event", "Coverage Report Row", True),
    ("PositionRegistered", "Entry snapshot (notional, APR, day-count basis)", False),
    ("AccrualUpdated", "Each accrual period (dt, delta, isInRange)", False),
    ("PositionOutOfRange", "Coverage paused (Reactive Network detected)", False),
    ("PositionBackInRange", "Coverage resumed (Reactive Network detected)", False),
    ("ClaimSettled", "Final settlement (IL, payout, limitingFactor)", False),
]
ry0 = ty + 0.12
rh = 0.31
for j, (ev, row, hdr) in enumerate(rows):
    yy = ry0 + j * rh
    col1 = ACCENT if hdr else WHITE
    col2 = SLATE if hdr else SLATE
    txt(s, 1.2, yy, 4.0, rh,
        [[{"t": ev, "size": 13.5, "color": col1, "bold": hdr, "font": CODE_FONT}]],
        anchor=MSO_ANCHOR.MIDDLE)
    txt(s, 5.0, yy, 0.4, rh, [[{"t": "→", "size": 13, "color": ACCENT, "bold": True}]],
        anchor=MSO_ANCHOR.MIDDLE)
    txt(s, 5.5, yy, 6.7, rh,
        [[{"t": row, "size": 13.5, "color": (ACCENT if hdr else WHITE), "bold": hdr}]],
        anchor=MSO_ANCHOR.MIDDLE)
    if hdr:
        line(s, 1.2, yy + rh, 11.0, color=SLATE, weight=1)
centerbox(s, 1.0, 6.5, 11.33, 0.8, [
    [{"t": "No off-chain assumptions. Fully verifiable.", "size": 15, "color": ACCENT, "bold": True, "space_after": 1}],
    [{"t": "Built on Reactive Network cross-chain automation.", "size": 15, "color": ACCENT, "bold": True}],
])
notes(s,
"This is the key differentiator. Every LP gets a verifiable, day-by-day coverage statement — "
"built entirely from on-chain events. Every row maps to a real transaction. The accrual periods "
"show whether the position was in range. Because the accrual basis is explicit — the day-count "
"convention, the APR, the entry notional — every row can be independently recomputed from the "
"event data. It's not a black box. The range transitions were detected autonomously by the "
"Reactive Network running on Lasna. And the settlement row shows exactly which cap was the "
"binding constraint. Let me show you.\n\n"
"Browser narration — Demo mode: Here's the full 45-day lifecycle. Every row maps to a real "
"on-chain event. Accrual periods show in range, earning coverage. The out-of-range pause "
"detected by the Reactive Network. Resumption. Final settlement — IL cap was the binding "
"constraint, payout 2.23 USDC. Each accrual row shows elapsed time, delta earned using A/365F, "
"and the in-range flag. The day-count convention makes this auditable — not a black box. Live "
"mode: Reading real events from Sepolia right now. Every LP in this pool can pull up their own "
"verifiable coverage statement. Buffer at 10,000 USDC, growing from real swap fees. "
"Self-sustaining by design.\n\n"
"Verbal transition: RangeGuard makes IL coverage predictable, auditable, and comparable — "
"because the day-count convention turns coverage from a black-box reward into an auditable "
"financial accrual.")

# ================================================================ SLIDE 9
s = add_slide()
centerbox(s, 1.0, 0.5, 11.33, 0.7,
          [[{"t": "“Protect your liquidity. Guard your range.”",
             "size": 28, "color": ACCENT, "bold": True, "italic": True}]],
          anchor=MSO_ANCHOR.TOP)
fbul = [
    "Native IL coverage — built into the pool, not bolted on",
    "Self-funding buffer — swap fees cover the claims",
    "Capped payouts — actuarially sound, buffer protected",
    "Fully auditable — every accrual verifiable on-chain",
]
txt(s, 1.5, 1.45, 10.3, 1.7,
    [[{"t": "✓  " + b, "size": 17, "color": WHITE, "space_after": 6}] for b in fbul])
# beneficiary table
ty = 3.35
card(s, 1.5, ty, 10.33, 1.85, fill=CARD)
bens = [
    ("Who Benefits", "Why It Matters", True),
    ("Passive LPs", "Downside protection without complex hedging", False),
    ("Protocols / DAOs", "Deeper liquidity without reliance on emissions", False),
    ("Uniswap Ecosystem", "Durable liquidity, tighter spreads, better execution", False),
]
by0 = ty + 0.14; brh = 0.42
for j, (a, b, hdr) in enumerate(bens):
    yy = by0 + j * brh
    txt(s, 1.85, yy, 3.4, brh,
        [[{"t": a, "size": 14.5, "color": (ACCENT if hdr else WHITE), "bold": True}]],
        anchor=MSO_ANCHOR.MIDDLE)
    txt(s, 5.3, yy, 6.3, brh,
        [[{"t": b, "size": 14, "color": (SLATE if hdr else SLATE)}]],
        anchor=MSO_ANCHOR.MIDDLE)
    if hdr:
        line(s, 1.85, yy + brh - 0.02, 9.6, color=SLATE, weight=1)
centerbox(s, 1.0, 5.4, 11.33, 0.5,
          [[{"t": "Earned over time. Funded by swaps. Settled on-chain.",
             "size": 20, "color": ACCENT, "bold": True}]])
line(s, 4.665, 6.0, 4.0, color=SLATE, weight=1)
centerbox(s, 1.0, 6.15, 11.33, 0.5, [
    [{"t": "range-guard.vercel.app    ·    github.com/garykocsis/RangeGuard",
      "size": 15, "color": WHITE, "bold": True}],
])
centerbox(s, 1.0, 6.6, 11.33, 0.35,
          [[{"t": "Built on Uniswap v4   ·   Powered by Reactive Network   ·   Deployed on Sepolia",
             "size": 13, "color": SLATE}]])
centerbox(s, 1.0, 6.98, 11.33, 0.32,
          [[{"t": "292 tests passing   ·   Fuzz tested   ·   Invariant tested",
             "size": 12, "color": SLATE}]])
notes(s,
"RangeGuard proves that impermanent loss coverage doesn't require a separate protocol, an oracle, "
"or off-chain infrastructure. It's native — built directly into the pool, funded by the same "
"swap activity it protects against, capped to keep the buffer solvent, and settled automatically "
"on withdrawal. The primary beneficiaries are passive and semi-passive LPs — they get downside "
"protection without complex hedging strategies. But the impact extends to protocols and DAOs "
"that need sticky liquidity without relying on token emissions, and to the broader Uniswap "
"ecosystem through deeper pools, tighter spreads, and better execution. The coverage statement "
"is auditable by anyone, recomputable from on-chain events, and expressed in a standard "
"financial day-count convention. Earned over time. Funded by swaps. Settled on-chain. The live "
"dashboard is at range-guard.vercel.app. Full source and 292 passing tests on GitHub. Thank you.")

# ---------------------------------------------------------------- save
out = "/Users/gkocsis/atrium_uhi/RangeGuard/docs/RangeGuard-Demo-Deck.pptx"
prs.save(out)
print("saved", out, "slides:", len(prs.slides._sldIdLst))
