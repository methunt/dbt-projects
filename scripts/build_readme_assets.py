"""Build a README's animated SVGs, one dark and one light variant each.

Why a generator rather than hand-written files: the light and dark variants
differ only by palette, and the figures on them come from the project's own
data. Hand-maintaining both guarantees they drift apart the first time a number
changes. Here one spec plus two palettes produces every variant, and the numbers
are read from the same file that produced them.

Animation notes, learned the hard way about GitHub:

  * GitHub strips <style> and <script> from markdown, so CSS cannot live in the
    README. It DOES run CSS inside an .svg referenced as <img>, which is why the
    animation lives in the asset rather than the page.
  * No external fonts can load - a proxied SVG has no network access - so every
    text element uses a generic system stack.
  * GitHub cannot be forced into dark mode. Both variants are emitted and the
    README picks between them with <picture> and prefers-color-scheme.
  * Entrances animate transform only, never opacity. A renderer that ignores CSS
    must still show a fully legible banner.

Usage:
    python build_readme_assets.py
    python build_readme_assets.py --spec readme-assets.json --out assets

Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import string
import sys
from pathlib import Path

FONT = "system-ui,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
MONO = "ui-monospace,SFMono-Regular,'SF Mono',Consolas,'Liberation Mono',monospace"

# Light is meant to be replaced with the project's own theme colours, so the
# README and its screenshots read as one piece of work. Dark is tuned to
# GitHub's dark surface rather than being light inverted.
LIGHT = {
    "name": "light",
    "bg": "#FFFFFF", "card": "#F6F8FA", "card2": "#EEF1F5", "border": "#D0D7DE",
    "text": "#1F2328", "muted": "#656D76", "faint": "#8C959F",
    "primary": "#2563EB", "good": "#059669", "warn": "#D97706", "bad": "#DC2626",
    "violet": "#7C3AED", "cyan": "#0891B2", "track": "#E4E8EC",
    "glow": "#2563EB", "glowopacity": "0.07", "ctashadow": "0.34",
    # Section-banner wash. Dark needs more of it: a 10% tint reads as nothing
    # against #0D1117, where the same value is clearly visible against white.
    "wash": "0.10",
}
DARK = {
    "name": "dark",
    "bg": "#0D1117", "card": "#161B22", "card2": "#1C2128", "border": "#30363D",
    "text": "#E6EDF3", "muted": "#8B949E", "faint": "#484F58",
    "primary": "#3B82F6", "good": "#10B981", "warn": "#F59E0B", "bad": "#EF4444",
    "violet": "#8B5CF6", "cyan": "#22D3EE", "track": "#21262D",
    # A coloured drop shadow that reads on white disappears on #0D1117, so dark
    # leans on a stronger one to keep the button lifted off the page.
    "glow": "#3B82F6", "glowopacity": "0.16", "ctashadow": "0.55",
    "wash": "0.22",
}

ACCENTS = {"primary", "good", "warn", "bad", "violet", "cyan"}

# Shared by every asset: entrances move, never fade, and always concede to
# prefers-reduced-motion.
MOTION = """
    .rise  { animation: rise .55s cubic-bezier(.2,.7,.3,1) both; }
    @keyframes rise { from { transform: translateY(9px) } to { transform: translateY(0) } }
    @media (prefers-reduced-motion: reduce) { * { animation: none !important } }"""


def esc(s: str) -> str:
    """Escape XML text. One raw & from a project name breaks the whole file."""
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def esc_attr(s: str) -> str:
    """Escape for an attribute value, not text content.

    esc() is not enough here. A double quote inside an attribute closes it
    early, the SVG stops being well-formed, and GitHub renders a malformed SVG
    as nothing at all - blank space, no error. Titles with quoted phrases and
    any command line carrying shell quotes both hit this.
    """
    return esc(s).replace('"', "&quot;")


def fill(text: str, facts: dict) -> str:
    """Substitute {key} and {key:format} from the facts dict.

    A missing key raises rather than rendering blank, so a renamed field fails
    the build instead of silently shipping a gap in the banner.
    """
    if not isinstance(text, str) or "{" not in text:
        return text
    try:
        return string.Formatter().vformat(text, (), facts)
    except KeyError as e:
        sys.exit(f"error: spec references unknown fact {e} in: {text!r}")
    except (ValueError, TypeError) as e:
        sys.exit(f"error: bad format spec in {text!r}: {e}")


def paint(template: str, p: dict) -> str:
    """Substitute __TOKEN__ placeholders.

    Used instead of str.format so the CSS braces in the templates need no
    escaping.
    """
    out = template
    for k, v in p.items():
        out = out.replace(f"__{k.upper()}__", str(v))
    return out.replace("__FONT__", FONT).replace("__MONO__", MONO)


def wrap(text: str, width: int) -> list[str]:
    """Greedy character-budget wrap. Approximate by design - exact text metrics
    are not available without a font, and banner copy is short enough that a
    character budget is close enough."""
    lines: list[str] = []
    line = ""
    for word in text.split():
        candidate = f"{line} {word}".strip()
        if len(candidate) > width and line:
            lines.append(line)
            line = word
        else:
            line = candidate
    if line:
        lines.append(line)
    return lines


def accent(name: str, where: str) -> str:
    if name not in ACCENTS:
        sys.exit(f"error: {where} has unknown accent {name!r}; "
                 f"expected one of {', '.join(sorted(ACCENTS))}")
    return f"__{name.upper()}__"


# --------------------------------------------------------------------------- #
# Hero
# --------------------------------------------------------------------------- #

def hero(spec: dict, facts: dict) -> str:
    """The hero banner - eyebrow and subtitle only.

    No title, no KPI tiles, and no badge pills. The project name lives as a
    real `<h1>` in the README, wrapped in the same link as this image, so a
    search engine and a screen reader both get the name as text rather than
    pixels inside an `<img>`. `spec["title"]` is required anyway, but only to
    drive `aria-label` and the paste-this-heading instructions main() prints -
    it is never drawn. KPI tiles are gone for the same reason "the three
    problems it solves" table stopped repeating the money-goes card strip:
    four numbers with no axis to compare them against read as decoration, not
    evidence - put real figures in a `strips` card instead. Badge pills are
    gone because the skeleton already has a badge row directly under the hero
    (see structure.md) - a stack/language/status badge repeated a few lines
    apart, once as SVG pixels and once as a shields.io image, said the same
    thing twice for no reason.
    """
    if "title" not in spec:
        sys.exit(f"error: hero {spec.get('name', 'hero')!r} needs a title, "
                  f"even though it isn't drawn - it drives aria-label and the "
                  f"<h1> this asset expects the README to carry above it")
    eyebrow = esc(fill(spec.get("eyebrow", ""), facts))
    subtitle = fill(spec.get("subtitle", ""), facts)
    note = esc(fill(spec.get("note", ""), facts))
    col = accent(spec.get("accent", "primary"), "hero")

    # Every row is positioned off the one above it, so an eyebrow-less hero or
    # a one-line subtitle still gets a canvas sized to what is actually on it -
    # not to a slot for text that isn't there.
    eyebrow_y = 74
    rule_y = (eyebrow_y + 34) if eyebrow else 50
    sub_lines = wrap(subtitle, 108) if subtitle else []
    sub_step = 34
    y = rule_y
    sub_svg = ""
    for i, line in enumerate(sub_lines):
        y = rule_y + 38 + i * sub_step
        sub_svg += f"""
  <text class="rise" style="animation-delay:{0.2 + i * 0.05:.2f}s" x="40" y="{y}"
        font-family="__FONT__" font-size="25" fill="__MUTED__">{esc(line)}</text>"""
    note_svg = ""
    if note:
        y += sub_step if sub_lines else 38
        note_svg = f"""
  <text class="rise" style="animation-delay:.25s" x="40" y="{y}"
        font-family="__MONO__" font-size="18" fill="__MUTED__">{note}</text>"""

    height = y + 40

    eyebrow_svg = ""
    if eyebrow:
        eyebrow_svg = f"""
  <text class="rise" x="40" y="{eyebrow_y}" font-family="__FONT__" font-size="22" font-weight="700"
        letter-spacing="3" fill="{col}">{eyebrow.upper()}</text>"""

    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 {height}"
     width="1200" height="{height}" role="img" aria-label="{esc_attr(fill(spec["title"], facts))}">
  <style>
    /* Entrance animations move things but never fade them. A renderer that does
       not run CSS - GitHub's mobile app, an email digest, a PDF export - would
       otherwise show an empty banner, because the from-state of a fade is
       invisible and fill-mode `both` holds it for the whole delay. Every element
       here is fully legible with the animation stripped out. */{MOTION}
    .sweep {{ animation: sweep .9s cubic-bezier(.2,.7,.3,1) .15s; }}
    .blob  {{ animation: drift 14s ease-in-out infinite alternate; }}
    @keyframes sweep {{ from {{ width: 0 }} to {{ width: 1120px }} }}
    @keyframes drift {{ from {{ transform: translate(0,0) }}
                        to   {{ transform: translate(64px,-22px) }} }}
  </style>
  <defs>
    <radialGradient id="g" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="__GLOW__" stop-opacity="__GLOWOPACITY__"/>
      <stop offset="100%" stop-color="__GLOW__" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <!-- The panel paints the theme's own card colour rather than staying
       transparent, so the hero reads as a deliberate surface on all four
       GitHub backgrounds instead of borrowing whichever one sits behind it. -->
  <rect width="1200" height="{height}" rx="16" fill="__CARD__"/>
  <rect x="0.5" y="0.5" width="1199" height="{height - 1}" rx="15.5" fill="none" stroke="__BORDER__"/>
  <rect width="8" height="{height}" rx="4" fill="{col}"/>
  <g class="blob"><circle cx="1010" cy="70" r="240" fill="url(#g)"/></g>{eyebrow_svg}
  <rect class="sweep" x="40" y="{rule_y}" width="1120" height="2"
        rx="1" fill="__BORDER__"/>{sub_svg}{note_svg}
</svg>
"""


# --------------------------------------------------------------------------- #
# Section caption (renders under a real <h2> - see structure.md)
# --------------------------------------------------------------------------- #

def caption(spec: dict, facts: dict) -> str:
    """A caption strip for the sentence under a section's real `<h2>`.

    This used to be called `banner()` and drew the eyebrow and title as SVG
    text - which meant "Part 2 - dbt on BigQuery" existed on the page only as
    pixels inside an `<img>`, invisible to search and to a screen reader.
    `spec["eyebrow"]` and `spec["title"]` are still required, but only to
    compose `aria-label` and the exact `<h2>` text main() prints for you to
    paste above the image - see structure.md for where that heading goes.
    Everything actually drawn here is `spec["body"]`, wrapped, next to an
    accent bar. Light-only by convention: see svg-assets.md.
    """
    if "eyebrow" not in spec or "title" not in spec:
        sys.exit(f"error: caption {spec.get('name')!r} needs eyebrow and title, "
                  f"even though neither is drawn - they compose the <h2> text "
                  f"main() prints for you to paste above this image")
    body = fill(spec.get("body", ""), facts)
    col = accent(spec.get("accent", "primary"), f"caption {spec.get('name')}")
    # Sizes are chosen for the RENDERED result, not the source. The canvas is
    # 1200 wide and GitHub's content column is ~900, so everything here is seen
    # at 0.75x: a 12px source size arrives as 9px. Divide by 1.33 to see what
    # the reader actually gets, and keep the result above 11px.
    lines = wrap(body, 104)
    first_y, step = 46, 32
    height = first_y + max(0, len(lines) - 1) * step + 34

    body_svg = "".join(f"""
  <text x="40" y="{first_y + i * step}" font-family="__FONT__" font-size="22"
        fill="__MUTED__">{esc(line)}</text>""" for i, line in enumerate(lines))

    label = esc_attr(f"{fill(spec['eyebrow'], facts)} - {fill(spec['title'], facts)}")

    # The wash is a tint of the accent, not a solid fill: a solid band fights the
    # page on every one of GitHub's four surfaces.
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 {height}"
     width="1200" height="{height}" role="img" aria-label="{label}">
  <style>{MOTION}</style>
  <defs>
    <linearGradient id="w" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="{col}" stop-opacity="__WASH__"/>
      <stop offset="100%" stop-color="{col}" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect width="1200" height="{height}" rx="12" fill="__CARD__"/>
  <rect width="1200" height="{height}" rx="12" fill="url(#w)"/>
  <rect width="6" height="{height}" rx="3" fill="{col}"/>
  <g class="rise">{body_svg}
  </g>
</svg>
"""


# --------------------------------------------------------------------------- #
# Card strip - 2 or 3 cards side by side, e.g. a "why this matters" banner
# --------------------------------------------------------------------------- #

def cards(spec: dict, facts: dict) -> str:
    """A row of 2-3 stat cards - the business-case banner, not a heading.

    Unlike hero() and caption(), this one is not standing in for a heading, so
    it keeps its own icon/title/stat baked into the SVG - there is no `<h2>`
    for it to duplicate. Use it for the "why does this matter" or "where does
    this help" banner the reader wants right after the pitch, each stat pulled
    from `facts` so it cannot drift from what the project's own data shows.
    """
    items = spec.get("cards", [])
    if not (2 <= len(items) <= 3):
        sys.exit(f"error: card strip {spec.get('name')!r} holds 2 or 3 cards; "
                  f"more will not fit 1200px")

    gap = 20
    w = (1200 - gap * (len(items) - 1)) // len(items)
    wrapped = [wrap(fill(c.get("body", ""), facts), 36) for c in items]
    body_y0, body_step = 158, 31
    height = body_y0 + max(len(b) for b in wrapped) * body_step + 56

    out = []
    for i, (c, body) in enumerate(zip(items, wrapped)):
        col = accent(c.get("colour", "primary"), f"card {i + 1}")
        x = i * (w + gap)
        lines = "".join(f"""
    <text x="{x + 28}" y="{body_y0 + j * body_step}" font-family="__FONT__" font-size="21"
          fill="__MUTED__">{esc(line)}</text>""" for j, line in enumerate(body))
        foot_y = height - 32
        out.append(f"""
  <g class="rise" style="animation-delay:{0.15 + i * 0.12:.2f}s">
    <rect x="{x}" y="0" width="{w}" height="{height}" rx="14" fill="__CARD__" stroke="__BORDER__"/>
    <rect x="{x}" y="0" width="{w}" height="5" rx="2.5" fill="{col}"/>
    <circle cx="{x + 52}" cy="64" r="28" fill="{col}" fill-opacity="0.14"/>
    <text x="{x + 52}" y="75" text-anchor="middle" font-family="__FONT__"
          font-size="29">{esc(c.get("icon", ""))}</text>
    <text x="{x + 28}" y="124" font-family="__FONT__" font-size="26" font-weight="700"
          fill="__TEXT__" letter-spacing="-0.4">{esc(fill(c.get("title", ""), facts))}</text>{lines}
    <rect x="{x + 28}" y="{foot_y - 23}" width="{w - 56}" height="1" fill="__BORDER__"/>
    <text x="{x + 28}" y="{foot_y}" font-family="__FONT__" font-size="19.5" font-weight="700"
          fill="{col}" letter-spacing="0.3">{esc(fill(c.get("stat", ""), facts))}</text>
  </g>""")

    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 {height}"
     width="1200" height="{height}" role="img" aria-label="{esc_attr(spec.get('label', 'Feature strip'))}">
  <style>{MOTION}</style>
{''.join(out)}
</svg>
"""


# --------------------------------------------------------------------------- #
# Call-to-action button
# --------------------------------------------------------------------------- #

def cta(spec: dict, facts: dict) -> str:
    label = esc(fill(spec["label"], facts))
    sublabel = esc(fill(spec.get("sublabel", ""), facts))
    col = accent(spec.get("accent", "primary"), "cta")

    # Rendered at 1320 and displayed at width="660" for a 2x effective
    # resolution. It paints no page background - only the pill - so it sits
    # cleanly on all four GitHub surfaces including dark dimmed (#22272E).
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1320 152"
     width="1320" height="152" role="img" aria-label="{esc_attr(fill(spec["label"], facts))}">
  <style>{MOTION}
    .sheen {{ animation: sheen 4.5s ease-in-out infinite 1.4s; }}
    @keyframes sheen {{ from {{ transform: translateX(-200px) }}
                        to   {{ transform: translateX(1320px) }} }}
  </style>
  <defs>
    <linearGradient id="btn" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="{col}" stop-opacity="1"/>
      <stop offset="100%" stop-color="{col}" stop-opacity="0.86"/>
    </linearGradient>
    <filter id="sh" x="-20%" y="-40%" width="140%" height="200%">
      <feDropShadow dx="0" dy="6" stdDeviation="9" flood-color="{col}"
                    flood-opacity="__CTASHADOW__"/>
    </filter>
    <clipPath id="clip"><rect x="210" y="18" width="900" height="92" rx="46"/></clipPath>
    <linearGradient id="sheenfade" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0"/>
      <stop offset="50%" stop-color="#FFFFFF" stop-opacity="0.16"/>
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <g class="rise">
    <rect x="210" y="18" width="900" height="92" rx="46" fill="url(#btn)" filter="url(#sh)"/>
    <g clip-path="url(#clip)">
      <rect class="sheen" x="210" y="18" width="150" height="92" fill="url(#sheenfade)"/>
    </g>
    <!-- Font sizes look oversized in the source because the asset is drawn at
         1320 and displayed at width="660" - halve them to judge the result. -->
    <text x="660" y="{60 if sublabel else 74}" text-anchor="middle" font-family="__FONT__"
          font-size="36" font-weight="700" fill="#FFFFFF">{label}</text>
    <text x="660" y="90" text-anchor="middle" font-family="__FONT__" font-size="24"
          fill="#FFFFFF" opacity="0.86">{sublabel}</text>
  </g>
</svg>
"""


# --------------------------------------------------------------------------- #
# Terminal cast
# --------------------------------------------------------------------------- #

# Neither toolkit has a UI to screenshot, so the closest honest equivalent of a
# page tour is the run itself. These are real captured runs against the BigQuery
# report and semantic model in this repo, not mock-ups - which is the only
# reason the numbers on them can be trusted.
CAST_ROLES = {"text", "muted", "faint", "good", "warn", "bad",
              "primary", "violet", "cyan"}


def cast(spec: dict, facts: dict) -> str:
    """A terminal card: a prompt line, then captured output lines.

    Lines rise in sequence to suggest a run in progress. Transform only - a
    renderer that drops the CSS shows the finished output, which is the state
    that carries the information.
    """
    command = esc(fill(spec["command"], facts))
    col = accent(spec.get("accent", "primary"), f"cast {spec.get('name')}")
    lines_in = spec.get("lines", [])
    if not lines_in:
        sys.exit(f"error: cast {spec.get('name')!r} has no lines")

    pad, lh = 30, 26
    top = 100                     # below the title bar and the prompt line
    height = top + len(lines_in) * lh + 18

    rows = []
    for i, item in enumerate(lines_in):
        if isinstance(item, str):
            item = {"t": item}
        role = item.get("c", "muted")
        if role not in CAST_ROLES:
            sys.exit(f"error: cast line role {role!r} not in "
                     f"{', '.join(sorted(CAST_ROLES))}")
        weight = "700" if item.get("bold") else "400"
        text = esc(fill(item.get("t", ""), facts))
        # Stagger is capped so a long capture does not take ten seconds to land.
        delay = min(0.055 * i, 1.25)
        rows.append(f"""
  <g class="ln" style="animation-delay:{delay:.2f}s"><text x="{pad}"
        y="{top + i * lh}" font-family="__MONO__" font-size="15.5"
        font-weight="{weight}" fill="__{role.upper()}__"
        xml:space="preserve">{text}</text></g>""")

    caret_y = top + len(lines_in) * lh - 4
    # The caret is deliberately static. It was the only element animating
    # opacity, and an opacity keyframe is exactly the thing that leaves an asset
    # invisible in a renderer that half-applies the CSS - not worth a blink.
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 {height}"
     width="1200" height="{height}" role="img"
     aria-label="Captured terminal output of: {esc_attr(fill(spec["command"], facts))}">
  <style>{MOTION}
    .ln {{ animation: rise .4s cubic-bezier(.2,.7,.3,1) both; }}
  </style>
  <rect width="1200" height="{height}" rx="12" fill="__CARD__"/>
  <rect x="0.5" y="0.5" width="1199" height="{height - 1}" rx="11.5"
        fill="none" stroke="__BORDER__"/>
  <path d="M0 12a12 12 0 0 1 12-12h1176a12 12 0 0 1 12 12v28H0z" fill="__CARD2__"/>
  <line x1="0" y1="40" x2="1200" y2="40" stroke="__BORDER__"/>
  <circle cx="26" cy="20" r="5" fill="__BAD__" opacity="0.7"/>
  <circle cx="44" cy="20" r="5" fill="__WARN__" opacity="0.7"/>
  <circle cx="62" cy="20" r="5" fill="__GOOD__" opacity="0.7"/>
  <!-- muted, not faint: faint (#484F58) against the dark card (#161B22) is
       effectively invisible - checked against a rasterised preview. -->
  <text x="600" y="25" text-anchor="middle" font-family="__FONT__"
        font-size="15" fill="__MUTED__">{esc(fill(spec.get("caption", ""), facts))}</text>
  <text x="{pad}" y="72" font-family="__MONO__" font-size="15.5"
        xml:space="preserve"><tspan fill="{col}" font-weight="700">$ </tspan><tspan fill="__TEXT__">{command}</tspan></text>
  <rect x="{pad}" y="{caret_y}" width="8" height="2" fill="{col}"/>{"".join(rows)}
</svg>
"""


# --------------------------------------------------------------------------- #
# Companion-repo manifest - a styled directory listing, NOT a captured
# command. Bespoke to this repo (a repo-index hub, not a runnable project),
# so it lives here rather than in the shared skill script.
# --------------------------------------------------------------------------- #

def manifest(spec: dict, facts: dict) -> str:
    """A dbt-flavoured directory listing of the companion repos.

    Deliberately NOT built on cast() and deliberately carries no `$ command`
    prompt line: cast() exists for a real captured run, and dressing a
    fabricated `dbt list` invocation up as terminal output would be exactly
    the mock-up-as-evidence the skill's cast() rule forbids. This is honestly
    labelled as what it is - a styled index - monospace and dbt-flavoured
    because the subject is a CLI tool, not because it pretends to be one.
    """
    rows_in = spec.get("rows", [])
    if not rows_in:
        sys.exit(f"error: manifest {spec.get('name')!r} has no rows")

    pad, row_h = 30, 60
    top = 76
    height = top + len(rows_in) * row_h + 22

    type_w = 92
    rows = []
    for i, r in enumerate(rows_in):
        col = accent(r.get("colour", "primary"), f"manifest row {i + 1}")
        y = top + i * row_h
        rtype = esc(fill(r["type"], facts))
        name = esc(fill(r["name"], facts))
        desc = esc(fill(r.get("desc", ""), facts))
        rows.append(f"""
  <g class="ln" style="animation-delay:{min(0.06 * i, 0.6):.2f}s">
    <rect x="{pad}" y="{y}" width="{type_w}" height="26" rx="4" fill="{col}" fill-opacity="0.14"/>
    <text x="{pad + type_w / 2:.0f}" y="{y + 18}" text-anchor="middle" font-family="__MONO__"
          font-size="16" font-weight="700" fill="{col}">{rtype}</text>
    <text x="{pad + type_w + 18}" y="{y + 18}" font-family="__MONO__" font-size="17"
          font-weight="700" fill="__TEXT__">{name}</text>
    <text x="{pad + type_w + 18}" y="{y + 40}" font-family="__FONT__" font-size="15.5"
          fill="__MUTED__">{desc}</text>
  </g>""")

    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 {height}"
     width="1200" height="{height}" role="img" aria-label="{esc_attr(spec.get('label', 'Companion repos'))}">
  <style>
    .ln {{ animation: rise .45s cubic-bezier(.2,.7,.3,1) both; }}
    @keyframes rise {{ from {{ transform: translateY(8px) }} to {{ transform: translateY(0) }} }}
    @media (prefers-reduced-motion: reduce) {{ .ln {{ animation: none }} }}
  </style>
  <rect width="1200" height="{height}" rx="12" fill="__CARD__"/>
  <rect x="0.5" y="0.5" width="1199" height="{height - 1}" rx="11.5" fill="none" stroke="__BORDER__"/>
  <path d="M0 12a12 12 0 0 1 12-12h1176a12 12 0 0 1 12 12v28H0z" fill="__CARD2__"/>
  <line x1="0" y1="40" x2="1200" y2="40" stroke="__BORDER__"/>
  <circle cx="26" cy="20" r="5" fill="__BAD__" opacity="0.5"/>
  <circle cx="44" cy="20" r="5" fill="__WARN__" opacity="0.5"/>
  <circle cx="62" cy="20" r="5" fill="__GOOD__" opacity="0.5"/>
  <text x="600" y="25" text-anchor="middle" font-family="__MONO__" font-size="15" font-weight="700"
        letter-spacing="1.2" fill="__MUTED__">COMPANION REPOS</text>
{''.join(rows)}
</svg>
"""


# --------------------------------------------------------------------------- #

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--spec", default="readme-assets.json")
    ap.add_argument("--out", default=None, help="overrides out_dir in the spec")
    args = ap.parse_args()

    spec_path = Path(args.spec).resolve()
    if not spec_path.exists():
        sys.exit(f"error: no spec at {spec_path}")
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    root = spec_path.parent

    facts: dict = {}
    if spec.get("facts_from"):
        facts_path = (root / spec["facts_from"])
        if not facts_path.exists():
            facts_path = Path(spec["facts_from"])
        if not facts_path.exists():
            sys.exit(f"error: facts_from not found: {spec['facts_from']}")
        facts = json.loads(facts_path.read_text(encoding="utf-8"))
    facts.update(spec.get("facts", {}))

    out = Path(args.out) if args.out else root / spec.get("out_dir", "assets")
    out.mkdir(parents=True, exist_ok=True)

    # Dual-theme jobs: hero, cta, casts, cards. Each gets a light and a dark
    # file, and the README picks between them with <picture>.
    dual_jobs: list[tuple[str, str]] = []
    if "hero" in spec:
        dual_jobs.append((spec["hero"].get("name", "hero"), hero(spec["hero"], facts)))
    for c in spec.get("casts", []):
        if "name" not in c:
            sys.exit("error: every cast needs a name")
        dual_jobs.append((c["name"], cast(c, facts)))
    for s in spec.get("strips", []):
        if "name" not in s:
            sys.exit("error: every card strip needs a name")
        dual_jobs.append((s["name"], cards(s, facts)))
    for m in spec.get("manifests", []):
        if "name" not in m:
            sys.exit("error: every manifest needs a name")
        dual_jobs.append((m["name"], manifest(m, facts)))
    if "cta" in spec:
        dual_jobs.append((spec["cta"].get("name", "cta"), cta(spec["cta"], facts)))

    # Light-only: the section captions that sit under a real <h2>. There is no
    # title baked into them to go illegible on a dark background, and shipping
    # one file instead of two is one fewer thing to keep in sync. See
    # svg-assets.md on why this is the standard for anything that stands in
    # for a heading, and dual_jobs above for anything that doesn't.
    caption_jobs: list[tuple[str, dict]] = []
    for b in spec.get("banners", []):
        if "name" not in b:
            sys.exit("error: every banner needs a name")
        caption_jobs.append((b["name"], b))

    if not dual_jobs and not caption_jobs:
        sys.exit("error: spec produced nothing - expected hero, banners, casts, strips or cta")

    overrides = spec.get("palette", {})
    written = 0
    for palette in (LIGHT, DARK):
        p = dict(palette)
        p.update({k.lower(): v for k, v in overrides.get(palette["name"], {}).items()})
        for name, template in dual_jobs:
            path = out / f"{name}-{palette['name']}.svg"
            # write_text with an explicit encoding, never PowerShell redirection:
            # a UTF-8 BOM in an SVG makes some renderers reject the file.
            path.write_text(paint(template, p), encoding="utf-8")
            written += 1
            print(f"  {path.relative_to(root) if root in path.parents else path}")

    light = dict(LIGHT)
    light.update({k.lower(): v for k, v in overrides.get("light", {}).items()})
    for name, b in caption_jobs:
        path = out / f"{name}-light.svg"
        path.write_text(paint(caption(b, facts), light), encoding="utf-8")
        written += 1
        print(f"  {path.relative_to(root) if root in path.parents else path}  (light-only)")
        stale_dark = out / f"{name}-dark.svg"
        if stale_dark.exists():
            stale_dark.unlink()
            print(f"  removed {stale_dark.relative_to(root)}  (light-only now)")

    print(f"{written} files written to {out}")

    print("\nHero - paste the <h1> above the <picture>, both inside the same link:\n")
    if "hero" in spec:
        name = spec["hero"].get("name", "hero")
        # Plain fill(), not esc() - this prints as literal markdown/HTML source
        # for the user to paste, not as text going inside an XML attribute.
        title = fill(spec["hero"]["title"], facts)
        print(f'<h1>{title}</h1>\n'
              f'<picture>\n'
              f'  <source media="(prefers-color-scheme: dark)" srcset="{out.name}/{name}-dark.svg">\n'
              f'  <img alt="DESCRIBE THE CONTENT" src="{out.name}/{name}-light.svg">\n'
              f'</picture>\n')

    if caption_jobs:
        print("Section captions - paste the anchor and <h2> above each light-only image:\n")
        for name, b in caption_jobs:
            title = fill(b["title"], facts)
            print(f'<a id="-{name}"></a>\n\n'
                  f'## {title}\n\n'
                  f'<img alt="DESCRIBE THE CONTENT" src="{out.name}/{name}-light.svg">\n')

    other = [(n, t) for n, t in dual_jobs
             if "hero" not in spec or n != spec["hero"].get("name", "hero")]
    if other:
        print("Everything else - dual-theme, reference with <picture>:\n")
        for name, _ in other:
            print(f'<picture>\n'
                  f'  <source media="(prefers-color-scheme: dark)" '
                  f'srcset="{out.name}/{name}-dark.svg">\n'
                  f'  <img alt="DESCRIBE THE CONTENT" src="{out.name}/{name}-light.svg">\n'
                  f'</picture>\n')


if __name__ == "__main__":
    main()
