#!/usr/bin/env python3
"""
Aggregate per-suite coverage JSON files (sim/coverage/<suite>.json) into a
single report. Outputs both a Markdown table to stdout and an HTML page
under sim/coverage/index.html.

Usage:
    python scripts/coverage_report.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
COV_DIR = REPO / "sim" / "coverage"


def load_suites():
    suites = {}
    if not COV_DIR.exists():
        return suites
    for jp in sorted(COV_DIR.glob("*.json")):
        with jp.open() as f:
            suites[jp.stem] = json.load(f)
    return suites


def render_markdown(suites):
    lines = []
    lines.append("# Functional Coverage Report")
    lines.append("")
    lines.append("Aggregated from cocotb-coverage runs of constrained-random suites.")
    lines.append("")
    if not suites:
        lines.append("_No coverage data — run `python scripts/run_tests.py soc_random core_random` first._")
        return "\n".join(lines)
    for name, points in suites.items():
        lines.append(f"## Suite: `{name}`")
        lines.append("")
        lines.append("| Cover point | Coverage |")
        lines.append("|-------------|----------|")
        for point, info in points.items():
            pct = info.get("cover_percentage", 0.0)
            lines.append(f"| `{point}` | {pct:.2f}% |")
        lines.append("")
    return "\n".join(lines)


def render_html(suites):
    parts = [
        "<!doctype html>",
        "<meta charset='utf-8'>",
        "<title>Functional Coverage Report</title>",
        "<style>",
        "  body{font-family:ui-monospace,Menlo,monospace;max-width:900px;margin:2em auto;padding:0 1em;color:#1e1e1e}",
        "  h1{border-bottom:2px solid #333}",
        "  h2{margin-top:2em;color:#005a9c}",
        "  table{border-collapse:collapse;width:100%}",
        "  td,th{border:1px solid #ccc;padding:6px 10px;text-align:left}",
        "  th{background:#f0f0f0}",
        "  td.pct{font-weight:600;text-align:right}",
        "  .lo{color:#b00}.mid{color:#a60}.hi{color:#080}",
        "</style>",
        "<h1>Functional Coverage Report</h1>",
    ]
    if not suites:
        parts.append("<p><em>No coverage data found.</em></p>")
        return "\n".join(parts)
    for name, points in suites.items():
        parts.append(f"<h2>Suite: <code>{name}</code></h2>")
        parts.append("<table><tr><th>Cover point</th><th>Coverage</th></tr>")
        for point, info in points.items():
            pct = float(info.get("cover_percentage", 0.0))
            cls = "hi" if pct >= 80 else ("mid" if pct >= 50 else "lo")
            parts.append(
                f"<tr><td><code>{point}</code></td>"
                f"<td class='pct {cls}'>{pct:.2f}%</td></tr>"
            )
        parts.append("</table>")
    return "\n".join(parts)


def main(argv: list[str]) -> int:
    suites = load_suites()
    md  = render_markdown(suites)
    print(md)
    if suites:
        html_path = COV_DIR / "index.html"
        html_path.write_text(render_html(suites), encoding="utf-8")
        sys.stderr.write(f"\nHTML report: {html_path}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
