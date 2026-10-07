# -*- coding: utf-8 -*-
"""
Builds IntuneRemediations-Presentation.pptx (21 slides, 16:9, native shapes).

Run:  python Tests\\Build-Presentation.py
"""
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
import os

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "IntuneRemediations-Presentation.pptx")

# ---------------------------------------------------------------- palette
PRIMARY   = RGBColor(0x00, 0x78, 0xD4)
PRIMARY_D = RGBColor(0x00, 0x5A, 0x9E)
NAVY      = RGBColor(0x1B, 0x3A, 0x5B)
CARD_BG   = RGBColor(0xEE, 0xF3, 0xFA)
CARD_BD   = RGBColor(0xC9, 0xD6, 0xE8)
TEXT      = RGBColor(0x22, 0x2E, 0x3B)
MUTED     = RGBColor(0x5B, 0x6B, 0x7C)
GREEN     = RGBColor(0x10, 0x7C, 0x10)
ORANGE    = RGBColor(0xC4, 0x3E, 0x1C)
WHITE     = RGBColor(0xFF, 0xFF, 0xFF)
ALT       = RGBColor(0xF5, 0xF8, 0xFC)
CHIP      = RGBColor(0xDC, 0xEA, 0xF8)
GREY_ARR  = RGBColor(0x8F, 0xA8, 0xC2)
FONT      = "Calibri"

prs = Presentation()
prs.slide_width  = Inches(13.333)
prs.slide_height = Inches(7.5)
BLANK = prs.slide_layouts[6]
_counter = {"n": 0}


# ---------------------------------------------------------------- helpers
def _set_text(tf, items, size=12, color=TEXT, bold=False, align=PP_ALIGN.LEFT,
              space_after=4, line_spacing=1.0):
    """items: list of str | (level, str) | (level, bold_lead, rest)"""
    tf.word_wrap = True
    first = True
    for it in items:
        if first and not tf.paragraphs[0].runs:
            p = tf.paragraphs[0]
            first = False
        else:
            first = False
            p = tf.add_paragraph()
        p.alignment = align
        p.space_after = Pt(space_after)
        p.line_spacing = line_spacing
        level = 0
        lead = None
        if isinstance(it, tuple):
            if len(it) == 3:
                level, lead, txt = it
            elif isinstance(it[0], str):
                lead, txt = it[0], (it[1] or "")
            else:
                level, txt = it
                txt = txt or ""
        else:
            txt = it
        p.level = min(int(level), 4)
        if lead is not None:
            r1 = p.add_run()
            r1.text = lead
            r1.font.bold = True
            r1.font.size = Pt(size)
            r1.font.name = FONT
            r1.font.color.rgb = color
        r = p.add_run()
        r.text = txt
        r.font.bold = bold
        r.font.size = Pt(size)
        r.font.name = FONT
        r.font.color.rgb = color


def base_slide(title, kicker=""):
    s = prs.slides.add_slide(BLANK)
    _counter["n"] += 1
    band = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, prs.slide_width, Inches(1.0))
    band.fill.solid(); band.fill.fore_color.rgb = PRIMARY
    band.line.fill.background(); band.shadow.inherit = False
    tb = s.shapes.add_textbox(Inches(0.45), Inches(0.14), Inches(10.4), Inches(0.72))
    tf = tb.text_frame
    p = tf.paragraphs[0]
    r = p.add_run(); r.text = title
    r.font.size = Pt(26); r.font.bold = True; r.font.name = FONT; r.font.color.rgb = WHITE
    if kicker:
        kb = s.shapes.add_textbox(Inches(10.7), Inches(0.30), Inches(2.3), Inches(0.4))
        kp = kb.text_frame.paragraphs[0]
        kp.alignment = PP_ALIGN.RIGHT
        kr = kp.add_run(); kr.text = kicker
        kr.font.size = Pt(11); kr.font.name = FONT; kr.font.color.rgb = RGBColor(0xCF, 0xE4, 0xF8)
    # footer
    fb = s.shapes.add_textbox(Inches(0.45), Inches(7.06), Inches(8.0), Inches(0.32))
    fp = fb.text_frame.paragraphs[0]
    fr = fp.add_run(); fr.text = "Intune Patch & App Remediation Pipeline"
    fr.font.size = Pt(9); fr.font.name = FONT; fr.font.color.rgb = MUTED
    nb = s.shapes.add_textbox(Inches(12.3), Inches(7.06), Inches(0.7), Inches(0.32))
    np_ = nb.text_frame.paragraphs[0]
    np_.alignment = PP_ALIGN.RIGHT
    nr = np_.add_run(); nr.text = str(_counter["n"])
    nr.font.size = Pt(9); nr.font.name = FONT; nr.font.color.rgb = MUTED
    return s


def notes(slide, text):
    slide.notes_slide.notes_text_frame.text = text


def card(slide, x, y, w, h, title, lines, body_size=11, accent=PRIMARY,
         fill=CARD_BG, title_size=13, numbered=False):
    box = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                                 Inches(x), Inches(y), Inches(w), Inches(h))
    box.fill.solid(); box.fill.fore_color.rgb = fill
    box.line.color.rgb = CARD_BD; box.line.width = Pt(0.75)
    box.shadow.inherit = False
    tf = box.text_frame
    tf.word_wrap = True
    tf.margin_left = Inches(0.14); tf.margin_right = Inches(0.14)
    tf.margin_top = Inches(0.08); tf.margin_bottom = Inches(0.06)
    p = tf.paragraphs[0]
    if title:
        r = p.add_run(); r.text = title
        r.font.size = Pt(title_size); r.font.bold = True
        r.font.name = FONT; r.font.color.rgb = accent
        p.space_after = Pt(4)
        items = lines
    else:
        items = lines
    _set_text(tf, items, size=body_size)
    return box


def arrow(slide, x, y, w, h, shape=MSO_SHAPE.RIGHT_ARROW, color=GREY_ARR):
    a = slide.shapes.add_shape(shape, Inches(x), Inches(y), Inches(w), Inches(h))
    a.fill.solid(); a.fill.fore_color.rgb = color
    a.line.fill.background(); a.shadow.inherit = False
    return a


def table(slide, x, y, col_widths, data, font=10, header_font=10.5,
          row_h=0.42, header_h=0.42):
    rows, cols = len(data), len(data[0])
    total_w = sum(col_widths)
    gf = slide.shapes.add_table(rows, cols, Inches(x), Inches(y),
                                Inches(total_w), Inches(header_h + (rows - 1) * row_h))
    tbl = gf.table
    for i, cw in enumerate(col_widths):
        tbl.columns[i].width = Inches(cw)
    tbl.rows[0].height = Inches(header_h)
    for ri in range(1, rows):
        tbl.rows[ri].height = Inches(row_h)
    for ri, row in enumerate(data):
        for ci, val in enumerate(row):
            cell = tbl.cell(ri, ci)
            cell.margin_left = Inches(0.07); cell.margin_right = Inches(0.05)
            cell.margin_top = Inches(0.02); cell.margin_bottom = Inches(0.02)
            cell.vertical_anchor = MSO_ANCHOR.MIDDLE
            cell.fill.solid()
            if ri == 0:
                cell.fill.fore_color.rgb = PRIMARY
            else:
                cell.fill.fore_color.rgb = WHITE if ri % 2 == 1 else ALT
            tf = cell.text_frame
            tf.word_wrap = True
            p = tf.paragraphs[0]
            r = p.add_run(); r.text = str(val)
            r.font.size = Pt(header_font if ri == 0 else font)
            r.font.name = FONT
            r.font.bold = (ri == 0)
            r.font.color.rgb = WHITE if ri == 0 else TEXT
    return tbl


def chevron(slide, x, y, w, h, l1, l2=""):
    ch = slide.shapes.add_shape(MSO_SHAPE.CHEVRON, Inches(x), Inches(y),
                                Inches(w), Inches(h))
    ch.fill.solid(); ch.fill.fore_color.rgb = PRIMARY
    ch.line.fill.background(); ch.shadow.inherit = False
    tf = ch.text_frame
    tf.word_wrap = True
    tf.margin_left = Inches(0.12); tf.margin_right = Inches(0.05)
    p = tf.paragraphs[0]; p.alignment = PP_ALIGN.CENTER
    r = p.add_run(); r.text = l1
    r.font.size = Pt(11); r.font.bold = True; r.font.name = FONT; r.font.color.rgb = WHITE
    if l2:
        p2 = tf.add_paragraph(); p2.alignment = PP_ALIGN.CENTER
        r2 = p2.add_run(); r2.text = l2
        r2.font.size = Pt(8.5); r2.font.name = FONT
        r2.font.color.rgb = RGBColor(0xD6, 0xEA, 0xFB)
    return ch


def step(slide, x, y, w, h, num, title, desc, num_color=PRIMARY):
    chip = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Inches(x), Inches(y + 0.07),
                                  Inches(0.46), Inches(0.46))
    chip.fill.solid(); chip.fill.fore_color.rgb = num_color
    chip.line.fill.background(); chip.shadow.inherit = False
    ctf = chip.text_frame; ctf.word_wrap = False
    cp = ctf.paragraphs[0]; cp.alignment = PP_ALIGN.CENTER
    cr = cp.add_run(); cr.text = str(num)
    cr.font.size = Pt(14); cr.font.bold = True; cr.font.name = FONT; cr.font.color.rgb = WHITE
    tb = slide.shapes.add_textbox(Inches(x + 0.58), Inches(y), Inches(w - 0.58), Inches(h))
    tf = tb.text_frame; tf.word_wrap = True
    p = tf.paragraphs[0]
    r1 = p.add_run(); r1.text = title + "  "
    r1.font.size = Pt(12); r1.font.bold = True; r1.font.name = FONT; r1.font.color.rgb = NAVY
    r2 = p.add_run(); r2.text = desc
    r2.font.size = Pt(11); r2.font.name = FONT; r2.font.color.rgb = TEXT
    p.line_spacing = 0.95


def strip(slide, x, y, w, h, text, fill=CHIP, color=NAVY, size=11, bold=True):
    box = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Inches(x), Inches(y),
                                 Inches(w), Inches(h))
    box.fill.solid(); box.fill.fore_color.rgb = fill
    box.line.color.rgb = CARD_BD; box.line.width = Pt(0.75)
    box.shadow.inherit = False
    tf = box.text_frame; tf.word_wrap = True
    tf.margin_left = Inches(0.15); tf.margin_right = Inches(0.15)
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    p = tf.paragraphs[0]
    r = p.add_run(); r.text = text
    r.font.size = Pt(size); r.font.bold = bold; r.font.name = FONT; r.font.color.rgb = color
    return box


# ================================================================ SLIDE 1
s = prs.slides.add_slide(BLANK)
_counter["n"] += 1
bg = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, prs.slide_width, prs.slide_height)
bg.fill.solid(); bg.fill.fore_color.rgb = NAVY
bg.line.fill.background(); bg.shadow.inherit = False
accent = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, Inches(4.62), prs.slide_width, Inches(0.09))
accent.fill.solid(); accent.fill.fore_color.rgb = PRIMARY
accent.line.fill.background(); accent.shadow.inherit = False
tb = s.shapes.add_textbox(Inches(0.9), Inches(1.9), Inches(11.6), Inches(1.6))
tf = tb.text_frame; tf.word_wrap = True
p = tf.paragraphs[0]
r = p.add_run(); r.text = "Intune Patch & App Remediation Pipeline"
r.font.size = Pt(40); r.font.bold = True; r.font.name = FONT; r.font.color.rgb = WHITE
p2 = tf.add_paragraph(); p2.space_before = Pt(14)
r2 = p2.add_run()
r2.text = ("Automated detection, error-code grouping and safe remediation "
          "of Windows Update and app installation failures")
r2.font.size = Pt(18); r2.font.name = FONT; r2.font.color.rgb = RGBColor(0xB9, 0xD6, 0xF2)
cb = s.shapes.add_textbox(Inches(0.9), Inches(5.0), Inches(11.6), Inches(1.2))
_set_text(cb.text_frame, [
    "Azure Automation  \u00b7  Microsoft Graph  \u00b7  Entra ID security groups  \u00b7  Intune Remediations",
    ("Architecture, workflow, error matrices, safety design, testing and operations"),
], size=14, color=RGBColor(0x9F, 0xC4, 0xE8))
cb.text_frame.paragraphs[1].runs[0].font.size = Pt(13)
db = s.shapes.add_textbox(Inches(0.9), Inches(6.55), Inches(11.6), Inches(0.4))
p = db.text_frame.paragraphs[0]
r = p.add_run(); r.text = "Repository: C:\\Users\\SAM\\Documents\\IntuneRemediations  \u00b7  October 2026"
r.font.size = Pt(11); r.font.name = FONT; r.font.color.rgb = RGBColor(0x7F, 0xA8, 0xCE)
notes(s, "Deck covers: why the pipeline exists (slides 2-3), how it is built (4-5), the "
         "end-to-end workflows (6-9), the detection/remediation contract and code matrices (10-15), "
         "quality assurance (16), and how to deploy and operate it (17-21). Every slide has notes.")

# ================================================================ SLIDE 2
s = base_slide("The Problem: Intune Failures Are Invisible and Untargeted", "Why")
card(s, 0.45, 1.3, 6.05, 1.95, "Failures drown in reports", [
    "Windows Update and app install errors are spread across thousands of device rows",
    "Root causes (disk, memory, WSUS policy, stuck installer...) are found by hand",
    "MTTR is measured in tickets, not minutes",
], body_size=11.5)
card(s, 6.83, 1.3, 6.05, 1.95, "Remediation cannot target the cause", [
    "Intune Remediations assign to groups - but error codes only exist inside reports",
    "One generic script is assigned to everyone, whatever actually failed",
    "Healthy devices get re-mediated; broken ones get the wrong fix",
], body_size=11.5)
card(s, 0.45, 3.45, 6.05, 1.95, "Scripts that hide or cause damage", [
    "Legacy patterns: chkdsk /r, winsock resets, DISM /ResetBase, killing every service",
    "\u201cExit 0 = success\u201d without verifying - loops run daily and never fix anything",
    "Detection bugs (registry Test-Path, English-only parsing) silently mis-fire",
], body_size=11.5, accent=ORANGE)
card(s, 6.83, 3.45, 6.05, 1.95, "No operational control loop", [
    "No grouping, no ownership markers, no dry-run before writing to the directory",
    "No paging/throttling handling - runs fail halfway at scale",
    "Nothing tells you when the automation itself broke",
], body_size=11.5, accent=ORANGE)
strip(s, 0.45, 5.7, 12.43, 0.75,
      "Goal: turn raw Graph failure states into error-code groups, target the right fix at the "
      "right devices, and prove every action was taken \u2014 safely.")
notes(s, "Open with the operational pain: admins export deviceStatuses/windowsUpdateStates, "
         "eyeball error codes, and build one-off fixes. The deck shows how this repo automates "
         "grouping and makes remediation precise and verifiable. Orange cards = risks the redesign removed.")

# ================================================================ SLIDE 3
s = base_slide("Solution: A Closed Loop in Three Moves", "Overview")
card(s, 0.45, 1.3, 3.98, 3.1, "1 \u00b7 Group per error code", [
    "Daily runbook reads Graph failure states",
    ("Each errorCode becomes an Entra security group:", None),
    "Intune-PatchError-{code}",
    "Intune-AppError-{code}",
    "Membership re-synced: devices leave the group when the failure clears",
], body_size=11.5, title_size=14)
card(s, 4.67, 1.3, 3.98, 3.1, "2 \u00b7 Target the remediation", [
    "Intune Remediation (detection + fix) is assigned to each error group",
    "Detection asks: \u201cdoes this device still show that condition?\u201d",
    "Exit 1 \u2192 remediation runs, only on those devices",
    "20+ patch codes and 35+ app codes covered",
], body_size=11.5, title_size=14)
card(s, 8.89, 1.3, 3.98, 3.1, "3 \u00b7 Fix safely, prove it", [
    "Idempotent, non-destructive actions only",
    "Post-action verification: Verified / Unknown \u2192 exit 0, Failed \u2192 exit 1",
    "Results land in the Intune remediation report per device",
    "Runbook failures throw \u2192 Azure Monitor alert",
], body_size=11.5, title_size=14, accent=GREEN)
chips = [("Managed identity", "no secrets stored"),
         ("-DryRun", "preview before write"),
         ("40 offline tests", "no tenant required"),
         ("Ownership marker", "hand-made groups safe")]
for i, (a, b) in enumerate(chips):
    x = 0.45 + i * 3.16
    strip(s, x, 4.75, 3.0, 0.9, "", fill=CARD_BG)
    tbx = s.shapes.add_textbox(Inches(x + 0.12), Inches(4.85), Inches(2.76), Inches(0.75))
    tf = tbx.text_frame; tf.word_wrap = True
    p = tf.paragraphs[0]
    r = p.add_run(); r.text = a
    r.font.size = Pt(13); r.font.bold = True; r.font.name = FONT; r.font.color.rgb = PRIMARY
    p2 = tf.add_paragraph()
    r2 = p2.add_run(); r2.text = b
    r2.font.size = Pt(10.5); r2.font.name = FONT; r2.font.color.rgb = MUTED
strip(s, 0.45, 5.95, 12.43, 0.62,
      "Outcome: failures re-group themselves every day; the right script runs on the right "
      "devices; nothing is claimed fixed unless it was checked.", fill=RGBColor(0xE3, 0xF3, 0xE3), color=GREEN)
notes(s, "The three-move framing is the elevator pitch. Emphasise the loop: device state \u2192 Graph "
         "\u2192 groups \u2192 remediation \u2192 device state. Membership re-sync means assignments "
         "auto-scope as errors appear and disappear \u2014 no manual group hygiene.")

# ================================================================ SLIDE 4
s = base_slide("Architecture at a Glance", "Workflow")
card(s, 0.45, 1.45, 2.7, 1.25, "Azure Automation", [
    "PowerShell runbooks, daily schedule",
    "Managed identity (Connect-MgGraph -Identity)",
], body_size=10.5, title_size=12.5)
arrow(s, 3.28, 1.9, 0.55, 0.35)
card(s, 3.95, 1.45, 2.5, 1.25, "Microsoft Graph", [
    "read failure states (beta)",
    "create/update groups + members",
], body_size=10.5, title_size=12.5)
# patch lane
card(s, 7.1, 1.15, 3.0, 1.0, None, [
    ("Patch lane", None),
    "windowsUpdateStates (beta)",
    "status = failed \u2192 errorCode",
], body_size=10, fill=RGBColor(0xE8, 0xF2, 0xFC))
arrow(s, 10.2, 1.5, 0.45, 0.3)
card(s, 10.75, 1.15, 2.4, 1.0, None, [
    "Entra groups",
    "Intune-PatchError-{code}",
], body_size=10, fill=RGBColor(0xE8, 0xF2, 0xFC))
# app lane
card(s, 7.1, 2.5, 3.0, 1.0, None, [
    ("App lane", None),
    "mobileApps (v1.0) + deviceStatuses",
    "installState = failed \u2192 errorCode",
], body_size=10, fill=RGBColor(0xE8, 0xF2, 0xFC))
arrow(s, 10.2, 2.85, 0.45, 0.3)
card(s, 10.75, 2.5, 2.4, 1.0, None, [
    "Entra groups",
    "Intune-AppError-{code}",
], body_size=10, fill=RGBColor(0xE8, 0xF2, 0xFC))
arrow(s, 1.5, 2.85, 0.35, 0.5, shape=MSO_SHAPE.DOWN_ARROW)
# remediation + devices row
card(s, 0.45, 4.35, 3.0, 1.35, "Windows devices", [
    "Entra joined / hybrid, Intune-managed",
    "Remediation runs as SYSTEM via IME",
], body_size=10.5, title_size=12.5)
arrow(s, 3.55, 4.85, 0.5, 0.35)
card(s, 4.2, 4.35, 4.4, 1.35, "Intune Remediations", [
    "Detection script \u2192 exit 0 compliant / exit 1 non-compliant",
    "Remediation script \u2192 State|Detail output, exit 0 fixed / exit 1 failed",
], body_size=10.5, title_size=12.5, accent=GREEN)
arrow(s, 8.75, 4.85, 0.5, 0.35)
card(s, 9.4, 4.35, 3.4, 1.35, "Assigned per group", [
    "One assignment per error-code group",
    "Scope follows membership automatically",
], body_size=10.5, title_size=12.5)
strip(s, 0.45, 6.0, 12.43, 0.6,
      "Closed loop: remediated devices change state \u2192 Graph reflects it \u2192 next run moves them "
      "out of the group \u2192 the assignment stops applying.")
notes(s, "Two parallel lanes share one sync engine. Patch lane: beta/deviceManagement/windowsUpdateStates. "
         "App lane: v1.0 mobileApps list (paged) with beta deviceStatuses per app. Writes: v1.0 groups API + "
         "$batch membership. The bottom strip explains why the system self-heals: membership is derived state, "
         "never set-and-forget.")

# ================================================================ SLIDE 5
s = base_slide("Repository Map", "Codebase")
table(s, 0.45, 1.3, [4.9, 7.5], [
    ["File", "Role"],
    ["IntuneUpdateErrorGroups.ps1", "Patch group-sync runbook (single source of truth): paging, retry, $batch, marker guard, sweep, -DryRun"],
    ["IntuneUpdateErrorGroups-Local.ps1", "Thin wrapper: installs Graph module, interactive sign-in, calls the runbook with -Interactive"],
    ["App\\IntuneAppErrorGroups.ps1", "App group-sync runbook: enumerates apps + failed deviceStatuses, then the same sync engine"],
    ["App\\IntuneAppErrorGroups-Local.ps1", "Thin wrapper for the app runbook (interactive login, -DryRun, -AppFilter)"],
    ["DetectionTemplate.ps1", "Patch detection: fast full scan or per-code targeted scan; exit 0/1 contract"],
    ["RemediationTemplate.ps1", "Patch remediation: safe actions per code + verification (Verified/Unknown/Failed)"],
    ["App\\DetectionTemplate.ps1", "App detection: pending reboot, stale msiexec, temp writability, report-only codes"],
    ["App\\RemediationTemplate.ps1", "App remediation: age-gated cleanup, wait/kill policy, guidance output for packaging issues"],
    ["ERROR-REFERENCE.md  (x2)", "Code \u2192 hex \u2192 detection \u2192 remediation tables for patches and apps"],
    ["AZURE-AUTOMATION-SETUP.md", "Identity, Graph app roles, module import, dry-run, schedule, alerting"],
    ["Tests\\Run-Tests.ps1", "Offline suite: parse checks, dot-source safety, Graph helpers, membership diff (40 assertions)"],
], font=10, header_font=11, row_h=0.44, header_h=0.4)
notes(s, "Design decision: Local variants used to duplicate ~130 lines each - they are now thin wrappers, "
         "so there is exactly one implementation per pipeline. The tests file is the regression gate: run it "
         "after any change (python-free, plain powershell -File).")

# ================================================================ SLIDE 6
s = base_slide("Patch Workflow: Error-Code Group Sync (9 Steps)", "Workflow")
steps = [
    ("Auth", "managed identity (runbook) or interactive sign-in (-Local); -DryRun previews everything"),
    ("Read", "paged GET beta/deviceManagement/windowsUpdateStates?$top=1000 - follows @odata.nextLink"),
    ("Filter", "keep status = failed with a deviceId; bucket rows by errorCode"),
    ("Match", "find Intune-PatchError-{code} (OData filter, quotes escaped); create with the automation marker if new"),
    ("Guard", "groups without 'Managed by automation' in the description are skipped - never touched"),
    ("Diff", "read all members (paged) and compare with target deviceIds: toAdd / toRemove sets"),
    ("Write", "$batch, 20 ops per call: POST members/$ref adds, DELETE removes; 409/404 are benign"),
    ("Sweep", "codes with zero current failures: members removed; group deleted only with -CleanupOrphanedGroups"),
    ("Report", "summary line with every count; any real failure \u2192 throw \u2192 job Failed \u2192 alert"),
]
for i, (t, d) in enumerate(steps[:5]):
    step(s, 0.45, 1.25 + i * 1.02, 6.15, 0.95, i + 1, t, d)
for i, (t, d) in enumerate(steps[5:]):
    step(s, 6.83, 1.25 + i * 1.02, 6.15, 0.95, i + 6, t, d)
strip(s, 6.83, 5.4, 6.15, 1.05,
      "Summary line (machine-readable):\n"
      "created=0 synced=3 cleared=1 deleted=0 membersAdded=5 membersRemoved=2\n"
      "membersSkipped=1 invalidDeviceIds=0 failures=0 dryRun=False",
      fill=RGBColor(0x1B, 0x3A, 0x5B), color=WHITE, size=10.5, bold=False)
notes(s, "Walk one error code end-to-end: device fails 0x80070070 \u2192 group "
         "Intune-PatchError--2147024784 created with marker \u2192 its deviceId added via $batch \u2192 "
         "Intune assignment targeting that group starts running detection on it \u2192 next day, if the error "
         "cleared, the sweep removes it. Note the double dash: prefix + '-2147024784'. Existing group names "
         "are preserved deliberately. Failures throw so Azure Automation marks the job failed.")

# ================================================================ SLIDE 7
s = base_slide("App Workflow: From App Catalog to Groups", "Workflow")
steps7 = [
    ("Auth", "same engine as the patch runbook; -DryRun supported"),
    ("Enumerate", "paged v1.0/deviceManagement/mobileApps; -AppFilter narrows by display name"),
    ("Per app", "beta .../deviceStatuses?$filter=installState eq 'failed' (paged, try/catch per app)"),
    ("Aggregate", "rows reduced to deviceId + errorCode; grouped by errorCode"),
    ("Sync + sweep", "identical to patch: marker guard, diff, $batch writes, stale-group emptying"),
]
for i, (t, d) in enumerate(steps7):
    step(s, 0.45, 1.3 + i * 1.05, 6.3, 1.0, i + 1, t, d)
card(s, 7.1, 1.3, 5.75, 1.55, "MSI installer codes 1601\u20131642", [
    "1601 service failed \u00b7 1602 user cancel \u00b7 1603 fatal \u00b7 1618 install in progress",
    "1619 package unreadable \u00b7 1632 temp unwritable \u00b7 1638 version conflict \u00b7 1641 reboot",
], body_size=10.5, title_size=12.5)
card(s, 7.1, 3.05, 5.75, 1.55, "Intune Win32 codes 0x87D0\u2026", [
    "-2016281111 detection said not installed \u00b7 -2016344807 requirement not met",
    "-2016281109/12/13/14 script failed / timeout / file / registry path",
], body_size=10.5, title_size=12.5)
card(s, 7.1, 4.8, 5.75, 1.55, "System codes (shared with patch lane)", [
    "-2147024784 disk \u00b7 -2147021879 reboot \u00b7 -2147024891 memory \u00b7 -2147024894 file missing",
    "Kept in the AppError prefix so app and patch groups never collide",
], body_size=10.5, title_size=12.5, accent=GREEN)
strip(s, 0.45, 6.45, 12.43, 0.55,
      "Scale note: app statuses are read sequentially (paged per app, \u2264500 apps per run); "
      "all membership writes are batched - the expensive part stays cheap.")
notes(s, "deviceStatuses exists only in beta today; mobileApps is read from v1.0. A per-app try/catch "
         "means one app with a broken status feed cannot abort the run (it counts as a failure and still "
         "surfaces in the summary). -AppFilter is useful for pilots: sync only one app's failures first.")

# ================================================================ SLIDE 8
s = base_slide("Graph Hardening: What Makes It Prod-Grade", "Reliability")
grid = [
    ("Pagination everywhere", [
        "Every list read loops on @odata.nextLink",
        "Old code stopped at page 1: 100 devices, 500 apps - silent truncation",
    ]),
    ("Throttle-aware retries", [
        "Exponential backoff + jitter on 429/500/502/503/504",
        "6 attempts, delay capped at 60s, then rethrow",
    ]),
    ("JSON $batch writes", [
        "20 membership ops per HTTP call",
        "5,000 devices \u2248 250 calls instead of ~10,000 individual POSTs",
    ]),
    ("Input validation", [
        "Device ids must be GUIDs; invalid ids counted + skipped",
        "If every target id is invalid the sync aborts - a bad feed cannot empty a group",
    ]),
    ("Directory ownership guard", [
        "Groups are only modified if the description contains 'Managed by automation'",
        "Look-alike groups created by humans get a warning, not a rewrite",
    ]),
    ("Fault isolation", [
        "Each group sync is its own try/catch",
        "Benign 409 (already member) / 404 (gone) are skipped; real errors count toward failures",
    ]),
]
for i, (t, lines) in enumerate(grid):
    x = 0.45 + (i % 3) * 4.22
    y = 1.3 + (i // 3) * 2.3
    card(s, x, y, 4.0, 2.1, t, lines, body_size=10.5, title_size=13)
strip(s, 0.45, 5.95, 12.43, 0.65,
      "Failure model: fatal errors and any non-benign membership failures make the runbook throw \u2192 "
      "Azure Automation marks the job Failed \u2192 your alert fires. Success is explicit, not assumed.")
notes(s, "The old implementation did one GET per device to check membership, never followed nextLink, "
         "and had no retry - at fleet scale it was guaranteed to throttle and silently mis-sync. "
         "All six properties are covered by Tests\\Run-Tests.ps1 with a mocked Invoke-MgGraphRequest.")

# ================================================================ SLIDE 9
s = base_slide("Group Lifecycle & Naming", "Lifecycle")
y = 1.5
chevron(s, 0.4, y, 2.6, 1.2, "No group", "error code absent")
chevron(s, 2.95, y, 2.6, 1.2, "Created + members", "first failure appears")
chevron(s, 5.5, y, 2.6, 1.2, "Re-synced daily", "membership tracks state")
chevron(s, 8.05, y, 2.6, 1.2, "Emptied", "code no longer occurs")
chevron(s, 10.6, y, 2.6, 1.2, "Deleted", "only with -Cleanup flag")
card(s, 0.45, 3.2, 6.05, 1.7, "Ownership marker (safety rail)", [
    "Created groups get: 'Managed by automation' in the description",
    "Marker present \u2192 sync, empty, or (with flag) delete",
    "Marker absent \u2192 warn and leave alone, even if the name matches",
], body_size=11)
card(s, 6.83, 3.2, 6.05, 1.7, "Naming (stable - not renamed)", [
    "Intune-PatchError--2147024784   (prefix + '-' + negative code = double dash)",
    "Intune-AppError-1618",
    "mailNickname sanitized to [a-zA-Z0-9]; display names preserved for existing tenants",
], body_size=11)
strip(s, 0.45, 5.2, 12.43, 1.3,
      "Why empty instead of delete?  An Intune assignment may target the group. Keeping the group with zero "
      "members simply stops the assignment from applying - deleting it would silently drop the assignment's "
      "scope. -CleanupOrphanedGroups is the explicit opt-in for removing the empty shell too.",
      fill=RGBColor(0xFD, 0xF3, 0xE7), color=RGBColor(0x8A, 0x53, 0x00), size=11.5, bold=False)
notes(s, "Lifecycle is fully derived: groups exist exactly as long as their error code does (when cleanup "
         "is enabled). The double-dash name quirk is intentional - renaming would orphan existing Intune "
         "assignments in live tenants. The strip answers the most common ops question: why don't you just "
         "delete stale groups?")

# ================================================================ SLIDE 10
s = base_slide("The Contract: Exit Codes and Report Output", "Contract")
card(s, 0.45, 1.3, 6.05, 1.65, "Detection script", [
    ("exit 0 \u2192 compliant: ", "take no action, device is fine"),
    ("exit 1 \u2192 non-compliant: ", "run the remediation script"),
    ("Detection error \u2192 exit 0 by default: ", "a broken check must not trigger fleet-wide fixes (-Strict flips this)"),
], body_size=11)
card(s, 6.83, 1.3, 6.05, 1.65, "Remediation script", [
    ("exit 0 \u2192 Verified or Unknown: ", "fixed, or honestly not provable"),
    ("exit 1 \u2192 Failed: ", "action ran but the condition remains - visible in Intune"),
    ("Old behaviour: ", "always exit 0 \u2192 broken remediations looked successful"),
], body_size=11, accent=GREEN)
table(s, 0.45, 3.25, [4.4, 4.6, 3.43], [
    ["Output line", "Example", "Where it appears"],
    ["Non-compliant|code|reason", "Non-compliant|-2147024784|Low disk space: 2.1 GB", "Intune - detection output"],
    ["State|detail (fixed)", "Verified|free space now 12.4 GB", "Intune - remediation output"],
    ["State|detail (not fixed)", "Failed|WUServer policy still missing", "Intune - remediation output"],
    ["Reboot / guidance", "RebootRequired|reboot pending, not forced", "Intune - remediation output"],
    ["Report-only codes", "ProductVersionConflict|fix supersede rules", "Intune - remediation output"],
], font=10, header_font=11, row_h=0.5, header_h=0.4)
strip(s, 0.45, 6.15, 12.43, 0.6,
      "Log files per device: %TEMP%\\IntuneDetection.log and %TEMP%\\IntuneRemediation.log "
      "(timestamped, appended, safe to pull during a support call).")
notes(s, "This contract is what closes the loop with operations: 'Failed' exits give you a live list of "
         "devices where the fix did not take, instead of an all-green report from scripts that never checked. "
         "Report-only codes (packaging problems) intentionally re-report daily so guidance stays visible "
         "without mutating the device.")

# ================================================================ SLIDE 11
s = base_slide("Patch Detection: Fast Scan + Targeted Scan", "Detection")
card(s, 0.45, 1.3, 6.05, 3.5, "Full scan (default, every cycle - fast)", [
    ("1. ", "pending reboot: registry VALUE PendingFileRenameOperations, WU RebootRequired, CBS RebootPending"),
    ("2. ", "disk free < 5 GB"),
    ("3. ", "free memory < 256 MB (was mislabeled 1 MB = 1 GB)"),
    ("4. ", "BITS: disabled service or errored jobs (not 'not running' - Manual start is normal)"),
    ("5. ", "partial WSUS policy, or missing WUServer with -RequireWUServer"),
    ("6. ", "DISM CheckHealth only with -IncludeSlowChecks (slow, so not in the hot path)"),
], body_size=11, title_size=13)
card(s, 6.83, 1.3, 6.05, 3.5, "Targeted scan (-TargetErrorCode, group context)", [
    "One switch case per code, stricter because the group proves intent:",
    ("-2145107951: ", "missing WUServer IS non-compliant here"),
    ("-2147010798: ", "DISM CheckHealth (exit code + 0x80073712 + text - locale tolerant)"),
    ("-2147012886: ", "resolve the WUServer host; cloud-only (no server) = compliant"),
    ("-2147023436 / -2145124305: ", "BITS disabled or jobs in error"),
    ("-2147023890: ", "volume dirty bit"),
    ("unknown code: ", "compliant - never loop on codes we cannot verify"),
], body_size=11, title_size=13, accent=PRIMARY_D)
card(s, 0.45, 5.0, 12.43, 1.6, "Bugs fixed in detection (all verified by tests / smoke runs)", [
    "Test-Path on PendingFileRenameOperations returned False for a registry VALUE - pending reboots were never detected",
    "WUServer-missing flagged every cloud-only device in full scan \u2192 daily false-positive remediation fleet-wide",
    "DISM output matched English-only text \u2192 broken on localized Windows; now exit code + hex marker + text",
    "Get-BitsTransfer 'count > 1' / 'BITS not running' heuristics false-positived on normal installs",
], body_size=10.5, title_size=12.5, accent=ORANGE)
notes(s, "Smoke-run proof: on the build machine the new detection exits 1 with "
         "'PendingFileRenameOperations set' - the old code exited 0 there because Test-Path can't see "
         "registry values. Targeted WUServer exits 1 only when targeted; full scan stays 0. Unknown "
         "target codes exit 0 so no remediation loop is possible.")

# ================================================================ SLIDE 12
s = base_slide("Patch Remediation Matrix (1 of 2)", "Remediation")
table(s, 0.45, 1.3, [1.7, 1.8, 5.5, 3.43], [
    ["Code (dec)", "Meaning", "Action taken", "Verification"],
    ["-2147024784", "Disk space", "Temp files >24h + WU download cache removed; DISM StartComponentCleanup (no /ResetBase)", "Free space re-check \u2192 Verified / Failed"],
    ["-2147021879", "Reboot pending", "Report only - never forces a reboot (org policy)", "Unknown + RebootRequired line"],
    ["-2147010798", "Component store", "DISM /RestoreHealth + SFC /ScanNow", "DISM exit code \u2192 Verified / Failed"],
    ["-2147023436", "WU timeout", "Enable BITS if disabled; reset WU cache (wuauserv/bits/cryptsvc)", "BITS enabled + no errored jobs"],
    ["-2145107951", "WUServer missing", "gpupdate /force, restart wuauserv, log policy keys", "WUServer present \u2192 Verified"],
    ["-2147012886", "DNS failure", "flushdns + registerdns + Clear-DnsClientCache", "Re-resolve WUServer host"],
    ["-2145124305", "Download failed", "Stop BITS, clear Downloader queue, start BITS", "No jobs in Error state"],
], font=10, header_font=11, row_h=0.62, header_h=0.42)
strip(s, 0.45, 6.2, 12.43, 0.55,
      "Every row is idempotent: re-running on the next cycle is harmless, and verification decides the exit code.")
notes(s, "Read the Verification column as the accountability mechanism. Examples: a disk-cleanup that "
         "frees nothing exits 1 (Failed) so ops sees it; DISM RestoreHealth is judged by its exit code; "
         "the reboot case is Unknown on purpose - we report but never auto-reboot, because forced reboots "
         "are a change-management decision.")

# ================================================================ SLIDE 13
s = base_slide("Patch Remediation Matrix (2 of 2)", "Remediation")
table(s, 0.45, 1.3, [1.55, 1.5, 3.05], [
    ["Code", "Meaning", "Action"],
    ["-2147012855", "Network timeout", "DNS cache + WU reset (no winsock - breaks VPN/LSP); guidance emitted"],
    ["-2147012867", "Server connect", "Restart WU services; log proxy + WSUS config"],
    ["-2145124320", "No user", "Report uptime only - transient, no changes"],
    ["-2145124341", "Cancelled", "WU cache reset + wuauclt resync"],
    ["-2147467260", "Aborted", "WU cache reset + resync (pending.xml never touched)"],
    ["-2147467259", "Unspecified", "Full WU reset (incl. catroot2) + RestoreHealth"],
], font=9.5, header_font=10.5, row_h=0.56, header_h=0.4)
table(s, 6.83, 1.3, [1.55, 1.5, 3.0], [
    ["Code", "Meaning", "Action"],
    ["-2147024891", "Low memory", "Report top-5 consumers + pagefile mode - never stops services"],
    ["-2016409844", "Scan timeout", "Kill msiexec/tiworker older than 2h only (never trustedinstaller)"],
    ["-2016409966", "Policy conflict", "gpresult /h report into %TEMP% for review"],
    ["-2146777998", "WU reg corrupt", "gpupdate + WU cache reset"],
    ["-2147023890", "Dirty disk", "Read-only Repair-Volume scan; chkdsk /f only with -AllowChkdsk"],
    ["-2147010815", "Assembly missing", "DISM /RestoreHealth (exit-code verified)"],
], font=9.5, header_font=10.5, row_h=0.56, header_h=0.4)
card(s, 0.45, 5.25, 12.43, 1.35, "-AutoDetect mode (remediation without an error code)", [
    "Checks in order: low disk \u2192 pending reboot \u2192 BITS disabled \u2192 low memory; otherwise exits 0 with 'no known issue'",
    "Old default ran DISM /RestoreHealth on every unknown state - heavy, slow, and unrelated to most conditions",
], body_size=11, title_size=12.5)
notes(s, "Codes without an automatic fix produce guidance in the Intune report instead of a risky action "
         "(policy conflicts, low memory, aborts). The dirty-disk row shows the flag pattern: default is a "
         "read-only scan; -AllowChkdsk schedules 'chkdsk C: /f' (never /r - /r can take hours). Intune "
         "cannot pass parameters, so the default is the safe one and the comment explains how to flip it.")

# ================================================================ SLIDE 14
s = base_slide("App Detection & Remediation Heuristics", "Apps")
card(s, 0.45, 1.3, 6.05, 4.7, "Detection", [
    ("Pending reboot: ", "same fixed registry-value read as the patch scripts"),
    ("1618 install-in-progress: ", "stale heuristic - msiexec running >20 min or >4 processes (count >1 was wrong: a healthy install is 2-3 processes)"),
    ("1632 temp unwritable: ", "real write+delete probe in %TEMP% (was a disk-space proxy)"),
    ("-2147024784 / -2147024891: ", "disk <5 GB / memory <256 MB"),
    ("1638 & -2147024894: ", "report-only - always non-compliant by design so the guidance line refreshes daily in the report"),
    ("Unknown target code: ", "compliant (no loop)"),
], body_size=11, title_size=13)
card(s, 6.83, 1.3, 6.05, 4.7, "Remediation", [
    ("1602 user cancel: ", "no-op + 're-assign if unexpected' guidance"),
    ("1603 fatal: ", "clear aged temp; kill msiexec only if >30 min old - never all msiexec, never unrelated DISM"),
    ("1618: ", "wait up to 15 min for the install to finish; kill only processes >1h old"),
    ("1619 package: ", "check temp access, then state 'source path is wrong - re-upload in Intune'"),
    ("1632: ", "age-gated temp clear \u2192 write probe \u2192 Verified / Failed"),
    ("-2016281109 script failed: ", "guidance only - execution policy is NOT changed (IME bypasses it, so flipping it never fixed anything)"),
], body_size=11, title_size=13, accent=GREEN)
strip(s, 0.45, 6.2, 12.43, 0.55,
      "Principle: device-fixable conditions get actions; packaging/config problems get precise guidance in "
      "the Intune report - never a blind mutation.", fill=RGBColor(0xE3, 0xF3, 0xE3), color=GREEN)
notes(s, "The 1618 heuristic change matters most: with 'msiexec count > 1', detection fired during every "
         "healthy install, which then triggered remediation to wait 15 minutes for the install it was "
         "interrupting. Stale-time (>20 min) plus an abnormal process count matches the real failure mode.")

# ================================================================ SLIDE 15
s = base_slide("Safety by Design: Before vs After", "Safety")
table(s, 0.45, 1.3, [4.3, 4.1, 4.03], [
    ["Before (risky default)", "After (this repo)", "Why"],
    ["DISM /StartComponentCleanup /ResetBase", "StartComponentCleanup only", "/ResetBase permanently blocks update uninstalls"],
    ["chkdsk C: /f /r scheduled automatically", "Read-only Repair-Volume scan; /f behind -AllowChkdsk, never /r", "/r can occupy the device for hours"],
    ["Stop every manual-start service on low memory", "Report top consumers + pagefile mode", "Killing services degrades a working device"],
    ["netsh winsock / ip reset", "DNS cache + WU service restart + guidance", "Winsock resets break VPN and LSP software"],
    ["Delete WinSxS\\pending.xml", "Never touched; guidance points to CBS.log", "Breaks servicing that is in flight"],
    ["Kill ALL msiexec on 1603", "Only processes >30 min old", "Aborts healthy installs in progress"],
    ["Always exit 0 after running steps", "Verified / Unknown \u2192 0, Failed \u2192 1", "Success must be proven, not assumed"],
    ["Set execution policy to RemoteSigned", "No policy changes; guidance only", "IME bypasses policy anyway - pure config drift"],
], font=9.5, header_font=10.5, row_h=0.53, header_h=0.4)
strip(s, 0.45, 6.35, 12.43, 0.5,
      "Temp cleanup is also age-gated (files >24h): running installers keep their scratch files.")
notes(s, "This slide is the risk story for management and the review checklist for security. Every 'after' "
         "behaviour is still effective for its error code - the difference is bounded blast radius and an "
         "honest exit code. The two design flags (-AllowChkdsk, -RequireWUServer) exist because those two "
         "actions are legitimate but environment-specific.")

# ================================================================ SLIDE 16
s = base_slide("Testing & Verification", "Quality")
table(s, 0.45, 1.3, [3.5, 0.9, 3.3], [
    ["Suite", "Checks", "What it proves"],
    ["Parse check (PS 5.1 parser)", "9", "Every .ps1 compiles - no syntax drift"],
    ["Dot-source safety", "6", "Loading a script never executes its main block"],
    ["Graph helpers (mocked)", "7", "Pagination, 429 retry, $batch 20+5 chunking"],
    ["Membership diff", "14", "Add/remove sets, GUID guard, DryRun, no-op"],
    ["Detection/remediation units", "7", "Helper contracts (reboot, BITS, temp, outcomes)"],
    ["Total", "40", "powershell -File Tests\\Run-Tests.ps1"],
], font=10.5, header_font=11, row_h=0.5, header_h=0.42)
card(s, 8.4, 1.3, 4.48, 3.7, "Live smoke runs (this machine)", [
    "Full-scan detection exits 1: 'PendingFileRenameOperations set' - the bug the old code hid",
    "Targeted WUServer \u2192 exit 1; cloud-only DNS target \u2192 exit 0",
    "Unknown code \u2192 compliant (no loop)",
    "Remediation: no code \u2192 exit 1; unknown code \u2192 exit 1; report-only \u2192 exit 0 with State|Detail",
    "App temp probe \u2192 compliant",
], body_size=10.5, title_size=13, accent=GREEN)
card(s, 0.45, 4.7, 7.75, 1.9, "Test design: offline by default", [
    "Invoke-MgGraphRequest and Start-Sleep are replaced by mocks - no tenant, no network, no cost",
    "CI-ready: a non-zero exit code fails the pipeline",
    "Docs are covered too: the parse check includes this generator's companion scripts",
], body_size=11, title_size=13)
strip(s, 8.4, 5.25, 4.48, 1.35,
      "40 / 40 passing\n\npowershell -File\n  Tests\\Run-Tests.ps1",
      fill=RGBColor(0xE3, 0xF3, 0xE3), color=GREEN, size=13, bold=True)
notes(s, "Regression story: the mocks make Graph behaviour deterministic (paged responses, a thrown 429, "
         "batch echo). The smoke runs validate the parts mocks cannot - real registry semantics, real exit "
         "codes, real detection/remediation flow on a live Windows build.")

# ================================================================ SLIDE 17
s = base_slide("Deployment: Azure Automation Setup", "Operations")
deploy = [
    ("Automation account", "create with system-assigned managed identity"),
    ("Graph app roles", "grant 4 roles to the identity: Directory.Read.All, Group.ReadWrite.All, DeviceManagementManagedDevices.Read.All, DeviceManagementApps.Read.All"),
    ("Module", "import Microsoft.Graph.Authentication only (runbooks use Invoke-MgGraphRequest)"),
    ("Runbooks", "upload IntuneUpdateErrorGroups.ps1 and App\\IntuneAppErrorGroups.ps1, publish"),
    ("Dry run", "Start with DryRun = true; review created/synced/planned-add counts"),
    ("Schedule", "daily link (e.g. 06:00) to both runbooks"),
    ("Alerting", "Azure Monitor alert on Scheduled job run failures \u2192 email/Teams"),
    ("Intune", "create Remediation packages; assign each to its Intune-*Error-{code} groups"),
]
for i, (t, d) in enumerate(deploy):
    x = 0.45 + (i % 2) * 6.38
    y = 1.3 + (i // 2) * 1.28
    step(s, x, y, 6.2, 1.2, i + 1, t, d)
strip(s, 0.45, 6.5, 12.43, 0.5,
      "Missing DeviceManagementApps.Read.All breaks only the app runbook; missing DeviceManagementManagedDevices.Read.All breaks the patch runbook.")
notes(s, "Callout: the original setup doc omitted DeviceManagementApps.Read.All - the app runbook would "
         "403 on every deviceStatuses query. Fixed in AZURE-AUTOMATION-SETUP.md along with module guidance "
         "(Microsoft.Graph.DeviceManagement is not needed) and the alert rule. Dry-run-first is now part of "
         "the documented procedure.")

# ================================================================ SLIDE 18
s = base_slide("Monitoring: Knowing It Works (and When It Doesn't)", "Operations")
card(s, 0.45, 1.3, 4.0, 2.6, "Automation side", [
    "Any real failure or partial-sync failure \u2192 throw \u2192 job Failed",
    "Azure Monitor: alert on runbook job failures",
    "Benign skips (409/404) are counted, not thrown",
    "Summary line is machine-parseable for dashboards",
], body_size=11, title_size=13)
card(s, 4.67, 1.3, 4.0, 2.6, "Device side", [
    "Remediation State|Detail lines appear per device in Intune",
    "Failed exits build a live 'did not fix' list",
    "%TEMP%\\IntuneDetection.log / IntuneRemediation.log for support",
    "Detection errors log and stay compliant (or exit 1 with -Strict)",
], body_size=11, title_size=13)
card(s, 8.89, 1.3, 4.0, 2.6, "Directory side", [
    "Group sizes = current failure counts per code",
    "A sudden group-size spike = regression in the field",
    "Marker guard means drift is detectable (warn on foreign groups)",
    "DryRun diff = review before every change window",
], body_size=11, title_size=13)
card(s, 0.45, 4.2, 12.43, 1.5, "Example alert flow", [
    "06:00 runbook starts \u2192 membership batch fails (throttled beyond retries) \u2192 throw after summary",
    "Azure Automation job = Failed \u2192 alert rule fires \u2192 Teams/email shows job output with the warnings",
    "Ops re-runs with DryRun, re-runs for real; devices were never in a half-synced state longer than one run",
], body_size=11, title_size=13, accent=ORANGE)
strip(s, 0.45, 5.95, 12.43, 0.6,
      "No silent failures: the system either reports success with counts or fails loudly.")
notes(s, "Three vantage points: the run (job status + summary), the device (Intune report + logs), and the "
         "directory (group sizes as a poor-man's dashboard). Suggested next step: a Azure Workbook that "
         "trends group membership over time from the same Graph data.")

# ================================================================ SLIDE 19
s = base_slide("Rollout Plan", "Operations")
table(s, 0.45, 1.3, [1.3, 5.0, 6.13], [
    ["Phase", "Action", "Pass criteria"],
    ["1 \u00b7 Offline", "powershell -File Tests\\Run-Tests.ps1", "40/40 pass; all files parse"],
    ["2 \u00b7 Dry run", "-Local wrapper with -DryRun against prod tenant", "Planned creates/adds/removes match expectations; zero invalid ids"],
    ["3 \u00b7 Pilot", "One error code, one small group, one Remediation assignment", "Detection fires on the right devices only; remediation Verified or honest Failed"],
    ["4 \u00b7 Full sync", "Schedule both runbooks daily; enable all assignments", "Two clean weeks of job runs; alerting armed"],
    ["5 \u00b7 Cleanup", "Enable -CleanupOrphanedGroups", "Only empty, marker-owned groups removed; assignments reviewed"],
], font=10.5, header_font=11, row_h=0.72, header_h=0.42)
strip(s, 0.45, 5.6, 12.43, 1.0,
      "Licensing checkpoint before Phase 3: Remediations require Windows Enterprise E3/E5, Education A3/A5, "
      "or VDA per user - confirm before assignments go live.",
      fill=RGBColor(0xFD, 0xF3, 0xE7), color=RGBColor(0x8A, 0x53, 0x00), size=12, bold=False)
notes(s, "Phases are ordered so the riskiest steps (directory writes, orphan deletion, fleet-wide "
         "assignments) each sit behind an evidence gate. Phase 5 is last on purpose: deleting groups "
         "touches assignment scope, so it waits for a clean operational history.")

# ================================================================ SLIDE 20
s = base_slide("Requirements, Permissions & Licensing", "Prerequisites")
card(s, 0.45, 1.3, 4.0, 4.4, "Licensing", [
    "Intune Remediations (formerly Proactive Remediations) require:",
    "\u2022 Windows Enterprise E3/E5 (incl. M365 F3/E3/E5)",
    "\u2022 Windows Education A3/A5",
    "\u2022 Windows VDA per user",
    "Devices: Entra joined/hybrid + MDM or co-managed, Win Pro/Ent/Edu",
    "Admin confirms licensing once in the Intune admin center",
], body_size=11, title_size=13, accent=ORANGE)
card(s, 4.67, 1.3, 4.0, 4.4, "Technical", [
    "PowerShell 5.1 (client + Azure Automation)",
    "Module: Microsoft.Graph.Authentication",
    "Managed identity for runbooks; delegated scopes locally",
    "Endpoints: windowsUpdateStates + deviceStatuses are beta (documented, no SLA); groups + mobileApps on v1.0",
    "Entra device objects used as group members (directoryObjects refs)",
], body_size=11, title_size=13)
card(s, 8.89, 1.3, 4.0, 4.4, "Permissions", [
    ("Runbook (managed identity): ", None),
    "\u2022 Directory.Read.All",
    "\u2022 Group.ReadWrite.All",
    "\u2022 DeviceManagementManagedDevices.Read.All",
    "\u2022 DeviceManagementApps.Read.All (app runbook)",
    ("Local (-Interactive): ", None),
    "same scopes via delegated sign-in; modules auto-installed for CurrentUser",
], body_size=11, title_size=13, accent=PRIMARY_D)
strip(s, 0.45, 6.0, 12.43, 0.6,
      "Beta endpoint note: if Microsoft moves windowsUpdateStates/deviceStatuses to v1.0, only the two URIs "
      "change - the sync engine is endpoint-agnostic.", size=11, bold=False)
notes(s, "Licensing is the silent killer for Remediations deployments - the feature shows up in the UI "
         "before everyone is licensed. Beta endpoints are called out honestly: they are the only API surface "
         "for this data today, and they are isolated behind Invoke-GraphGetAll so swapping them is a "
         "one-line change.")

# ================================================================ SLIDE 21
s = base_slide("Summary & Next Steps", "Wrap-up")
card(s, 0.45, 1.3, 6.05, 3.9, "Delivered in this hardening pass", [
    "Correctness: full pagination, registry-value reboot detection, WUServer false-positive fix, diff-based membership sync",
    "Reliability: 429/5xx backoff, $batch writes, per-group fault isolation, marker ownership guard",
    "Safety: destructive defaults removed (ResetBase, /r, winsock, pending.xml, service kills, policy flips)",
    "Honesty: Verified/Unknown/Failed outcomes with real exit codes",
    "Quality: 40-test offline suite + live smoke runs; docs regenerated",
    "Ops: -DryRun, alerting guidance, rollout phases",
], body_size=11, title_size=13, accent=GREEN)
card(s, 6.83, 1.3, 6.05, 3.9, "Ideas for the next iteration", [
    "Graph delta queries to shrink reads further",
    "Automate Intune assignment creation per generated group",
    "Azure Workbook dashboard: group sizes and remediation outcomes over time",
    "Localized detection variants for DISM-heavy checks",
    "Soft-delete awareness (recently deleted devices) in the sweep",
    "Pester migration if the team standardises on it",
], body_size=11, title_size=13, accent=PRIMARY)
strip(s, 0.45, 5.5, 12.43, 1.1,
      "Questions?   \u00b7   Repo: C:\\Users\\SAM\\Documents\\IntuneRemediations   \u00b7   "
      "Tests: Tests\\Run-Tests.ps1   \u00b7   Setup: AZURE-AUTOMATION-SETUP.md",
      fill=NAVY, color=WHITE, size=13, bold=True)
notes(s, "Close on the three numbers: 40 tests passing, ~20 patch + ~35 app error codes covered, and zero "
         "destructive defaults left in the remediation path. Then open the floor - demo the DryRun output "
         "live if the audience wants to see it.")

# ---------------------------------------------------------------- save
prs.core_properties.title = "Intune Patch & App Remediation Pipeline"
prs.core_properties.author = "IntuneRemediations"
prs.core_properties.subject = "Architecture, workflow, remediation matrices, safety and operations"
prs.save(OUT)
print("Saved:", OUT)
print("Slides:", len(prs.slides.__iter__.__self__._sldIdLst))
