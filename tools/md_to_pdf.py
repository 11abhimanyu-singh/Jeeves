#!/usr/bin/env python3
"""Minimal, dependency-light Markdown -> PDF for Jeeves docs.

Supports the subset the PRDs use: headings (#..######), tables, fenced
code blocks, unordered lists, blockquotes, horizontal rules, and inline
**bold** / *italic* / `code`. Renders with reportlab (no pandoc needed).
"""
import sys
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_LEFT
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    ListFlowable, ListItem, HRFlowable, Preformatted, KeepTogether,
)

# Warm palette (mirrors Jeeves ContentView.swift tokens)
PAPER = colors.HexColor("#F5EAD8")
SURFACE = colors.HexColor("#EBDDC5")
INK = colors.HexColor("#201E1D")
SOFT = colors.HexColor("#645C50")
MUTED = colors.HexColor("#6E6759")
ACCENT = colors.HexColor("#8C491A")      # accentDeep (passes contrast)
SAGE = colors.HexColor("#56633F")        # sageDeep
TRAVEL = colors.HexColor("#2E6E6E")      # travelInk-ish teal


def esc(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def inline(text: str) -> str:
    """Escape then re-introduce supported inline markup as reportlab tags."""
    text = esc(text)
    # inline code first (so its contents aren't further bolded)
    import re
    codes = []

    def stash(m):
        codes.append(m.group(1))
        return f"\x00{len(codes) - 1}\x00"

    text = re.sub(r"`([^`]+)`", stash, text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<i>\1</i>", text)
    text = re.sub(r"\x00(\d+)\x00",
                  lambda m: f'<font face="Courier" size="-1" color="#8C491A">{esc(codes[int(m.group(1))])}</font>',
                  text)
    return text


def build_styles():
    ss = getSampleStyleSheet()
    styles = {}
    styles["body"] = ParagraphStyle(
        "body", parent=ss["BodyText"], fontName="Helvetica", fontSize=9.5,
        leading=13.5, textColor=INK, spaceAfter=5, alignment=TA_LEFT)
    styles["h1"] = ParagraphStyle(
        "h1", parent=ss["Heading1"], fontName="Times-Bold", fontSize=20,
        textColor=ACCENT, spaceBefore=14, spaceAfter=8, leading=24)
    styles["h2"] = ParagraphStyle(
        "h2", parent=ss["Heading2"], fontName="Times-Bold", fontSize=14.5,
        textColor=INK, spaceBefore=12, spaceAfter=5, leading=18)
    styles["h3"] = ParagraphStyle(
        "h3", parent=ss["Heading3"], fontName="Times-Bold", fontSize=11.5,
        textColor=SAGE, spaceBefore=9, spaceAfter=3, leading=14)
    styles["h4"] = ParagraphStyle(
        "h4", parent=ss["Heading4"], fontName="Helvetica-Bold", fontSize=10.5,
        textColor=INK, spaceBefore=7, spaceAfter=2, leading=13)
    styles["quote"] = ParagraphStyle(
        "quote", parent=styles["body"], textColor=SOFT, fontSize=9, leading=12.5,
        leftIndent=10, borderColor=MUTED, spaceAfter=6)
    styles["cell"] = ParagraphStyle(
        "cell", parent=styles["body"], fontSize=8.3, leading=11, spaceAfter=0)
    styles["cellh"] = ParagraphStyle(
        "cellh", parent=styles["cell"], fontName="Helvetica-Bold",
        textColor=colors.white)
    styles["mono"] = ParagraphStyle(
        "mono", parent=ss["Code"], fontName="Courier", fontSize=8,
        textColor=INK, backColor=SURFACE, leading=11, borderPadding=6,
        spaceBefore=4, spaceAfter=6)
    return styles


def parse_table(rows):
    """rows: list of raw '| a | b |' strings. Returns header, body lists."""
    def split(r):
        r = r.strip()
        if r.startswith("|"):
            r = r[1:]
        if r.endswith("|"):
            r = r[:-1]
        return [c.strip() for c in r.split("|")]

    header = split(rows[0])
    body = [split(r) for r in rows[2:]]  # skip separator row[1]
    return header, body


def render(md_path, pdf_path):
    with open(md_path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    styles = build_styles()
    story = []
    i = 0
    n = len(lines)

    def flush_list(items):
        if items:
            flow = ListFlowable(
                [ListItem(Paragraph(inline(t), styles["body"]), leftIndent=12)
                 for t in items],
                bulletType="bullet", start="•", leftIndent=14, bulletColor=ACCENT)
            story.append(flow)
            story.append(Spacer(1, 3))

    while i < n:
        line = lines[i]
        stripped = line.strip()

        # blank
        if stripped == "":
            i += 1
            continue

        # fenced code
        if stripped.startswith("```"):
            i += 1
            buf = []
            while i < n and not lines[i].strip().startswith("```"):
                buf.append(lines[i]); i += 1
            i += 1  # closing fence
            story.append(Preformatted("\n".join(buf), styles["mono"]))
            continue

        # horizontal rule
        if set(stripped) == {"-"} and len(stripped) >= 3:
            story.append(Spacer(1, 2))
            story.append(HRFlowable(width="100%", thickness=0.6,
                                    color=SURFACE, spaceBefore=4, spaceAfter=6))
            i += 1
            continue

        # headings
        if stripped.startswith("#"):
            level = len(stripped) - len(stripped.lstrip("#"))
            text = stripped[level:].strip()
            key = f"h{min(level,4)}"
            story.append(Paragraph(inline(text), styles[key]))
            i += 1
            continue

        # blockquote (one or more consecutive > lines)
        if stripped.startswith(">"):
            buf = []
            while i < n and lines[i].strip().startswith(">"):
                buf.append(lines[i].strip().lstrip(">").strip()); i += 1
            story.append(Paragraph(inline(" ".join(buf)), styles["quote"]))
            continue

        # table: header + separator + rows
        if stripped.startswith("|") and i + 1 < n and lines[i + 1].strip().startswith("|") \
                and set(lines[i + 1].replace("|", "").replace(":", "").replace("-", "").replace(" ", "")) == set():
            rows = [stripped]
            i += 1
            while i < n and lines[i].strip().startswith("|"):
                rows.append(lines[i].strip()); i += 1
            header, body = parse_table(rows)
            data = [[Paragraph(inline(c), styles["cellh"]) for c in header]]
            for r in body:
                data.append([Paragraph(inline(c), styles["cell"]) for c in r])
            ncol = len(header)
            avail = A4[0] - 36 * mm
            widths = [avail / ncol] * ncol
            tbl = Table(data, colWidths=widths, repeatRows=1)
            tbl.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, 0), ACCENT),
                ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, SURFACE]),
                ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#DCD3C4")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 5),
                ("RIGHTPADDING", (0, 0), (-1, -1), 5),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]))
            story.append(Spacer(1, 3))
            story.append(tbl)
            story.append(Spacer(1, 7))
            continue

        # unordered list
        if stripped.startswith("- ") or stripped.startswith("* "):
            items = []
            while i < n and (lines[i].strip().startswith("- ") or lines[i].strip().startswith("* ")):
                items.append(lines[i].strip()[2:].strip()); i += 1
            flush_list(items)
            continue

        # plain paragraph (merge consecutive non-special lines)
        buf = [stripped]
        i += 1
        while i < n and lines[i].strip() != "" \
                and not lines[i].strip().startswith(("#", "|", ">", "- ", "* ", "```")) \
                and not (set(lines[i].strip()) == {"-"} and len(lines[i].strip()) >= 3):
            buf.append(lines[i].strip()); i += 1
        story.append(Paragraph(inline(" ".join(buf)), styles["body"]))
        story.append(Spacer(1, 2))

    doc = SimpleDocTemplate(
        pdf_path, pagesize=A4,
        leftMargin=18 * mm, rightMargin=18 * mm,
        topMargin=16 * mm, bottomMargin=16 * mm,
        title="Jeeves — Day Planner Usability & Abilities PRD",
        author="Jeeves")

    def footer(canvas, d):
        canvas.saveState()
        canvas.setStrokeColor(SURFACE)
        canvas.setLineWidth(0.5)
        canvas.line(18 * mm, 12 * mm, A4[0] - 18 * mm, 12 * mm)
        canvas.setFont("Helvetica", 7.5)
        canvas.setFillColor(MUTED)
        canvas.drawString(18 * mm, 8 * mm, "Jeeves · Day Planner Usability & Abilities PRD")
        canvas.drawRightString(A4[0] - 18 * mm, 8 * mm, "Page %d" % d.page)
        canvas.restoreState()

    doc.build(story, onFirstPage=footer, onLaterPages=footer)
    print(f"wrote {pdf_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: md_to_pdf.py <in.md> <out.pdf>")
        sys.exit(1)
    render(sys.argv[1], sys.argv[2])
